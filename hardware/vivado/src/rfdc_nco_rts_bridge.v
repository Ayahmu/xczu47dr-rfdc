`timescale 1ns / 1ps

// Transfers one complete eight-channel NCO configuration into the RFDC AXI/DRP
// clock domain. The source payload remains stable until the destination
// acknowledges the request, so the multi-bit buses use a bundled-data CDC
// alongside request/acknowledge toggles. In MTS mode Tile 0 controls the shared
// SYSREF gate: all Tile DRP loads finish while SYSREF is gated, then one common
// re-enable pulse allows the new NCO frequency/phase state to take effect.
module rfdc_nco_rts_bridge #(
    parameter integer TIMEOUT_CYCLES = 500000
) (
    input  wire         src_clk,
    input  wire         src_rst_n,
    input  wire         src_start,
    input  wire [7:0]   src_channel_mask,
    input  wire [383:0] src_nco_freq,
    input  wire [143:0] src_nco_phase,
    output reg          src_busy,
    output reg          src_done,
    output reg  [1:0]   src_error,
    output reg          src_sync_ready,
    output reg  [31:0]  src_sync_epoch,

    input  wire         rfdc_clk,
    input  wire         rfdc_rst_n,
    input  wire [4:0]   rfdc_tile_update_busy,
    output reg  [383:0] dac_nco_freq,
    output reg  [143:0] dac_nco_phase,
    output reg  [7:0]   dac_nco_phase_reset,
    output reg  [47:0]  dac_nco_update_enable,
    output reg  [3:0]   dac_tile_update_req,
    output reg          dac_sysref_int_gating,
    output reg          dac_sysref_int_reenable
);

  localparam [1:0] ERR_NONE         = 2'd0;
  localparam [1:0] ERR_BUSY_ASSERT  = 2'd1;
  localparam [1:0] ERR_BUSY_RELEASE = 2'd2;

  reg src_request_toggle;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] src_ack_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] src_error_sync_0;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] src_error_sync_1;
  reg [7:0]   src_mask_hold;
  reg [383:0] src_freq_hold;
  reg [143:0] src_phase_hold;

  reg dst_ack_toggle;
  reg [1:0] dst_error_hold;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] dst_request_sync;

  always @(posedge src_clk or negedge src_rst_n) begin
    if (!src_rst_n) begin
      src_request_toggle <= 1'b0;
      src_ack_sync <= 2'b00;
      src_error_sync_0 <= 2'b00;
      src_error_sync_1 <= 2'b00;
      src_mask_hold <= 8'd0;
      src_freq_hold <= 384'd0;
      src_phase_hold <= 144'd0;
      src_busy <= 1'b0;
      src_done <= 1'b0;
      src_error <= ERR_NONE;
      src_sync_ready <= 1'b0;
      src_sync_epoch <= 32'd0;
    end else begin
      src_ack_sync <= {src_ack_sync[0], dst_ack_toggle};
      src_error_sync_0 <= dst_error_hold;
      src_error_sync_1 <= src_error_sync_0;
      src_done <= 1'b0;

      if (src_start && !src_busy) begin
        src_mask_hold <= src_channel_mask;
        src_freq_hold <= src_nco_freq;
        src_phase_hold <= src_nco_phase;
        src_request_toggle <= ~src_request_toggle;
        src_busy <= 1'b1;
        src_error <= ERR_NONE;
        src_sync_ready <= 1'b0;
      end else if (src_busy && (src_ack_sync[1] == src_request_toggle)) begin
        src_busy <= 1'b0;
        src_done <= 1'b1;
        src_error <= src_error_sync_1;
        if (src_error_sync_1 == ERR_NONE) begin
          src_sync_ready <= 1'b1;
          src_sync_epoch <= src_sync_epoch + 32'd1;
        end else begin
          src_sync_ready <= 1'b0;
        end
      end
    end
  end

  localparam [3:0] D_IDLE            = 4'd0;
  localparam [3:0] D_SETTLE          = 4'd1;
  localparam [3:0] D_WAIT_IDLE       = 4'd2;
  localparam [3:0] D_REQUEST         = 4'd3;
  localparam [3:0] D_WAIT_ASSERT     = 4'd4;
  localparam [3:0] D_WAIT_LOAD_CLEAR = 4'd5;
  localparam [3:0] D_REENABLE        = 4'd6;
  localparam [3:0] D_WAIT_GATE_CLEAR = 4'd7;
  localparam [3:0] D_ACK             = 4'd8;

  reg [3:0] dst_state;
  reg [1:0] settle_count;
  reg [31:0] timeout_count;
  reg [7:0] dst_channel_mask;
  reg [3:0] dst_tile_mask;
  reg [3:0] dst_request_mask;
  reg [3:0] busy_seen;
  wire [3:0] tile_load_busy = {
      rfdc_tile_update_busy[4], rfdc_tile_update_busy[3],
      rfdc_tile_update_busy[2], rfdc_tile_update_busy[0]
  };
  wire tile0_gate_busy = rfdc_tile_update_busy[1];
  wire all_request_idle =
      ((tile_load_busy & dst_request_mask) == 4'd0) && !tile0_gate_busy;
  wire all_request_seen =
      (busy_seen & dst_request_mask) == dst_request_mask;
  wire all_load_clear = (tile_load_busy & dst_request_mask) == 4'd0;

  integer channel;
  always @(posedge rfdc_clk or negedge rfdc_rst_n) begin
    if (!rfdc_rst_n) begin
      dst_request_sync <= 2'b00;
      dst_ack_toggle <= 1'b0;
      dst_error_hold <= ERR_NONE;
      dst_state <= D_IDLE;
      settle_count <= 2'd0;
      timeout_count <= 32'd0;
      dst_channel_mask <= 8'd0;
      dst_tile_mask <= 4'd0;
      dst_request_mask <= 4'd0;
      busy_seen <= 4'd0;
      dac_nco_freq <= 384'd0;
      dac_nco_phase <= 144'd0;
      dac_nco_phase_reset <= 8'd0;
      dac_nco_update_enable <= 48'd0;
      dac_tile_update_req <= 4'd0;
      dac_sysref_int_gating <= 1'b0;
      dac_sysref_int_reenable <= 1'b0;
    end else begin
      dst_request_sync <= {dst_request_sync[0], src_request_toggle};
      dac_tile_update_req <= 4'd0;
      dac_sysref_int_reenable <= 1'b0;

      case (dst_state)
        D_IDLE: begin
          dac_nco_update_enable <= 48'd0;
          dac_nco_phase_reset <= 8'd0;
          dac_sysref_int_gating <= 1'b0;
          if (dst_request_sync[1] != dst_ack_toggle) begin
            settle_count <= 2'd2;
            dst_error_hold <= ERR_NONE;
            dst_state <= D_SETTLE;
          end
        end
        D_SETTLE: begin
          if (settle_count != 0) begin
            settle_count <= settle_count - 1'b1;
          end else begin
            dst_channel_mask <= src_mask_hold;
            dst_tile_mask <= {
                |src_mask_hold[7:6], |src_mask_hold[5:4],
                |src_mask_hold[3:2], |src_mask_hold[1:0]
            };
            // Tile 0 owns the global SYSREF gate, so it participates even
            // when the request only changes channels in Tiles 1-3.
            dst_request_mask <= {
                |src_mask_hold[7:6], |src_mask_hold[5:4],
                |src_mask_hold[3:2], 1'b1
            };
            dac_nco_freq <= src_freq_hold;
            dac_nco_phase <= src_phase_hold;
            dac_nco_phase_reset <= src_mask_hold;
            for (channel = 0; channel < 8; channel = channel + 1)
              dac_nco_update_enable[channel*6 +: 6] <=
                  src_mask_hold[channel] ? 6'h3f : 6'h00;
            timeout_count <= 32'd0;
            dst_state <= D_WAIT_IDLE;
          end
        end
        D_WAIT_IDLE: begin
          if (all_request_idle) begin
            dst_state <= D_REQUEST;
          end else if (timeout_count >= TIMEOUT_CYCLES - 1) begin
            dst_error_hold <= ERR_BUSY_RELEASE;
            dst_state <= D_ACK;
          end else begin
            timeout_count <= timeout_count + 1'b1;
          end
        end
        D_REQUEST: begin
          dac_sysref_int_gating <= 1'b1;
          dac_tile_update_req <= dst_request_mask;
          busy_seen <= 4'd0;
          timeout_count <= 32'd0;
          dst_state <= D_WAIT_ASSERT;
        end
        D_WAIT_ASSERT: begin
          busy_seen <= busy_seen | (tile_load_busy & dst_request_mask);
          if ((((busy_seen | tile_load_busy) & dst_request_mask) == dst_request_mask) &&
              tile0_gate_busy) begin
            timeout_count <= 32'd0;
            dst_state <= D_WAIT_LOAD_CLEAR;
          end else if (timeout_count >= TIMEOUT_CYCLES - 1) begin
            dst_error_hold <= ERR_BUSY_ASSERT;
            dst_state <= D_ACK;
          end else begin
            timeout_count <= timeout_count + 1'b1;
          end
        end
        D_WAIT_LOAD_CLEAR: begin
          if (all_request_seen && all_load_clear && tile0_gate_busy) begin
            timeout_count <= 32'd0;
            dst_state <= D_REENABLE;
          end else if (!tile0_gate_busy) begin
            dst_error_hold <= ERR_BUSY_RELEASE;
            dst_state <= D_ACK;
          end else if (timeout_count >= TIMEOUT_CYCLES - 1) begin
            dst_error_hold <= ERR_BUSY_RELEASE;
            dst_state <= D_ACK;
          end else begin
            timeout_count <= timeout_count + 1'b1;
          end
        end
        D_REENABLE: begin
          dac_sysref_int_reenable <= 1'b1;
          timeout_count <= 32'd0;
          dst_state <= D_WAIT_GATE_CLEAR;
        end
        D_WAIT_GATE_CLEAR: begin
          if (!tile0_gate_busy && all_load_clear) begin
            dst_state <= D_ACK;
          end else if (timeout_count >= TIMEOUT_CYCLES - 1) begin
            dst_error_hold <= ERR_BUSY_RELEASE;
            dst_state <= D_ACK;
          end else begin
            timeout_count <= timeout_count + 1'b1;
          end
        end
        D_ACK: begin
          dac_nco_update_enable <= 48'd0;
          dac_nco_phase_reset <= 8'd0;
          dac_sysref_int_gating <= 1'b0;
          dst_ack_toggle <= dst_request_sync[1];
          dst_state <= D_IDLE;
        end
        default: dst_state <= D_IDLE;
      endcase
    end
  end

endmodule
