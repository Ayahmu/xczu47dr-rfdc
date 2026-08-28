`timescale 1ns/1ps

// Single-pulse board synchronization sequencer.
//
// Master SYNC is generated in the mclk clock domain.  mclk is the HMC7044
// 10 MHz monitor clock returned to the FPGA and is phase-deterministic relative
// to the HMC7044 VCXO/VCO.  Slave XS20 bypasses FPGA mclk re-timing and is
// forwarded asynchronously to the HMC7044, whose internal SYNC re-timing is
// enabled by register 0x005B.
//
// clk (pl_clk) is retained only for the request CDC input and the sync_done
// status return path.  role_master is fixed by the selected master/slave
// bitstream.
module sync_role_control #(
    parameter integer IS_MASTER = 1,
    parameter integer WAIT_CYCLES = 20000,
    parameter integer HIGH_CYCLES = 40
) (
    input  wire clk,
    input  wire mclk,
    input  wire rst_n,
    input  wire sync_request,
    input  wire sync_in,
    input  wire role_master,
    input  wire sync_bypass,
    output wire hmc_sync,
    output wire slave_sync,
    output wire sync_done
);
  localparam integer WAIT_LAST = (WAIT_CYCLES < 1) ? 0 : WAIT_CYCLES - 1;
  localparam integer HIGH_LAST = (HIGH_CYCLES < 1) ? 0 : HIGH_CYCLES - 1;

  localparam [1:0] ST_IDLE = 2'd0;
  localparam [1:0] ST_WAIT = 2'd1;
  localparam [1:0] ST_HIGH = 2'd2;
  localparam [1:0] ST_DONE = 2'd3;

  // ===== pl_clk (clk) domain: request CDC + status return =====
  reg sync_req_meta, sync_req_sync, sync_req_prev;
  reg sync_in_meta, sync_in_sync, sync_in_prev;
  reg role_master_d;
  reg request_toggle_clk;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] done_toggle_clk_sync;
  reg done_toggle_clk_seen;
  reg sync_done_pulse;

  // ===== mclk domain: deterministic master SYNC pulse generation =====
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] request_toggle_mclk_sync;
  reg request_toggle_mclk_seen;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] role_master_mclk_sync;
  reg [1:0] state;
  reg [31:0] count;
  reg sync_pulse_mclk;
  reg done_toggle_mclk;

  wire role_master_selected = role_master;
  wire role_changed = (role_master_selected != role_master_d);
  wire sync_request_rise = sync_req_sync && !sync_req_prev;
  wire sync_input_rise = sync_in_sync && !sync_in_prev;
  wire request_rise_mclk = request_toggle_mclk_sync[1] != request_toggle_mclk_seen;
  wire role_master_mclk = role_master_mclk_sync[1];

  // ---- clk domain ----
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sync_req_meta <= 1'b0;
      sync_req_sync <= 1'b0;
      sync_req_prev <= 1'b0;
      sync_in_meta <= 1'b0;
      sync_in_sync <= 1'b0;
      sync_in_prev <= 1'b0;
      role_master_d <= IS_MASTER ? 1'b1 : 1'b0;
      request_toggle_clk <= 1'b0;
      done_toggle_clk_sync <= 2'b00;
      done_toggle_clk_seen <= 1'b0;
      sync_done_pulse <= 1'b0;
    end else begin
      sync_req_meta <= sync_request;
      sync_req_sync <= sync_req_meta;
      sync_req_prev <= sync_req_sync;
      sync_in_meta <= sync_in;
      sync_in_sync <= sync_in_meta;
      sync_in_prev <= sync_in_sync;
      role_master_d <= role_master_selected;
      done_toggle_clk_sync <= {done_toggle_clk_sync[0], done_toggle_mclk};
      done_toggle_clk_seen <= done_toggle_clk_sync[1];

      sync_done_pulse <= 1'b0;
      if (role_changed)
        request_toggle_clk <= 1'b0;
      else if (role_master_selected && sync_request_rise)
        request_toggle_clk <= ~request_toggle_clk;

      // Slave completes on a received XS20 rise; master completes when the
      // mclk-domain pulse generator toggles done back into this domain.
      if (!role_master_selected && sync_input_rise)
        sync_done_pulse <= 1'b1;
      else if (role_master_selected &&
               (done_toggle_clk_sync[1] != done_toggle_clk_seen))
        sync_done_pulse <= 1'b1;
    end
  end

  // ---- mclk domain ----
  always @(posedge mclk or negedge rst_n) begin
    if (!rst_n) begin
      request_toggle_mclk_sync <= 2'b00;
      request_toggle_mclk_seen <= 1'b0;
      role_master_mclk_sync <= IS_MASTER ? 2'b11 : 2'b00;
      state <= IS_MASTER ? ST_IDLE : ST_DONE;
      count <= 32'd0;
      sync_pulse_mclk <= 1'b0;
      done_toggle_mclk <= 1'b0;
    end else begin
      request_toggle_mclk_sync <= {request_toggle_mclk_sync[0], request_toggle_clk};
      request_toggle_mclk_seen <= request_toggle_mclk_sync[1];
      role_master_mclk_sync <= {role_master_mclk_sync[0], role_master_selected};

      if (!role_master_mclk) begin
        sync_pulse_mclk <= 1'b0;
        count <= 32'd0;
        state <= ST_DONE;
      end else begin
        case (state)
          ST_IDLE: begin
            sync_pulse_mclk <= 1'b0;
            count <= 32'd0;
            if (request_rise_mclk)
              state <= ST_WAIT;
          end
          ST_WAIT: begin
            sync_pulse_mclk <= 1'b0;
            if (count >= WAIT_LAST) begin
              count <= 32'd0;
              sync_pulse_mclk <= 1'b1;
              state <= ST_HIGH;
            end else begin
              count <= count + 1'b1;
            end
          end
          ST_HIGH: begin
            sync_pulse_mclk <= 1'b1;
            if (count >= HIGH_LAST) begin
              count <= 32'd0;
              sync_pulse_mclk <= 1'b0;
              done_toggle_mclk <= ~done_toggle_mclk;
              state <= ST_DONE;
            end else begin
              count <= count + 1'b1;
            end
          end
          ST_DONE: begin
            sync_pulse_mclk <= 1'b0;
            count <= 32'd0;
            if (request_rise_mclk)
              state <= ST_WAIT;
          end
          default: begin
            state <= ST_IDLE;
            count <= 32'd0;
            sync_pulse_mclk <= 1'b0;
          end
        endcase
      end
    end
  end

  // Master drives its own HMC7044 SYNC and the XS20 output with the same
  // deterministic pulse.  Slave forwards XS20 directly to its own HMC7044;
  // there is no FPGA mclk edge or latency in the slave HMC7044 path.
  assign hmc_sync = role_master_mclk ? sync_pulse_mclk : sync_in;
  assign slave_sync = role_master_mclk ? sync_pulse_mclk : 1'b0;
  assign sync_done = sync_done_pulse;

endmodule
