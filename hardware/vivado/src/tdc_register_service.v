`timescale 1ns/1ps
`default_nettype none

// One outstanding register transaction. Payloads stay stable until the
// acknowledgement has crossed back; a request is never acknowledged on enqueue.
module tdc_register_service #(
    parameter integer TAPS = 2048,
    parameter integer TAP_WIDTH = $clog2(TAPS)
) (
    input wire ddr_clk, ddr_rst_n, sample_clk, sample_rst_n,
    input wire reg_valid, reg_write,
    input wire [15:0] reg_addr,
    input wire [31:0] reg_wdata,
    output reg reg_ready,
    output reg [31:0] reg_rdata,
    output reg [15:0] reg_error,
    input wire armed_dac,
    input wire reference_ready,
    input wire monitor_toggle,
    input wire [255:0] monitor_data,
    input wire event_valid, event_good, event_overflow, event_bubble,
    input wire [31:0] event_epoch,
    input wire [10:0] event_phase_10ps,
    input wire [TAP_WIDTH-1:0] event_tap,
    output reg calib_wr_en,
    output reg [TAP_WIDTH-1:0] calib_wr_addr,
    output reg [15:0] calib_wr_data,
    output wire [TAP_WIDTH-1:0] calib_rd_addr,
    input wire [15:0] calib_rd_data,
    output wire compensation_enable,
    output wire calibration_source,
    output wire carrier_correction_enable,
    output reg calibration_valid,
    output reg signed [15:0] phase_offset_10ps,
    output reg clear_statistics_toggle
);
  reg [48:0] request_hold;
  reg request_toggle, inflight, wait_release;
  reg ack_toggle;
  reg [47:0] response_hold;
  (* ASYNC_REG = "TRUE" *) reg [2:0] ack_sync;
  (* ASYNC_REG = "TRUE" *) reg [2:0] sample_alive_sync;
  reg [47:0] response_meta, response_sync;
  always @(posedge ddr_clk or negedge ddr_rst_n) begin
    if (!ddr_rst_n) begin
      request_hold <= 0; request_toggle <= 0; inflight <= 0;
      wait_release <= 0; ack_sync <= 0; sample_alive_sync <= 0;
      response_meta <= 0; response_sync <= 0;
      reg_ready <= 0; reg_rdata <= 0; reg_error <= 0;
    end else begin
      ack_sync <= {ack_sync[1:0], ack_toggle};
      sample_alive_sync <= {sample_alive_sync[1:0], sample_rst_n};
      response_meta <= response_hold;
      response_sync <= response_meta;
      reg_ready <= 0;
      if (!reg_valid) wait_release <= 0;
      if (reg_valid && !inflight && !wait_release) begin
        request_hold <= {reg_write, reg_addr, reg_wdata};
        request_toggle <= !request_toggle;
        inflight <= 1;
        wait_release <= 1;
      end
      if (inflight && !sample_alive_sync[2]) begin
        reg_error <= 16'd9; reg_rdata <= 0; reg_ready <= 1; inflight <= 0;
      end else if (inflight && ack_sync[2] == request_toggle) begin
        reg_error <= response_sync[47:32];
        reg_rdata <= response_sync[31:0];
        reg_ready <= 1;
        inflight <= 0;
      end
    end
  end

  (* ASYNC_REG = "TRUE" *) reg [2:0] request_sync, armed_sync, monitor_sync;
  reg [48:0] request_meta, request_data;
  reg [255:0] monitor_meta, monitor_sampled, monitor_snapshot;
  reg monitor_seen;
  wire wr = request_data[48];
  wire [15:0] addr = request_data[47:32];
  wire [31:0] data = request_data[31:0];
  wire [15:0] lut_byte_offset = addr - 16'h1000;
  wire [TAP_WIDTH-1:0] lut_index = lut_byte_offset[TAP_WIDTH+1:2];
  assign calib_rd_addr = lut_index;
  reg [2:0] control;
  assign compensation_enable = control[0];
  assign calibration_source = control[1];
  assign carrier_correction_enable = control[2];
  reg [TAP_WIDTH:0] written_count;
  reg [15:0] previous_entry;
  reg [31:0] calibration_revision;
  (* ram_style = "distributed" *) reg [31:0] histogram [0:TAPS-1];
  reg histogram_clearing;
  reg [TAP_WIDTH-1:0] histogram_clear_address;
  reg [31:0] measured_count, invalid_count, overflow_count, bubble_count;
  reg [31:0] histogram_count, last_epoch, last_phase, last_raw;
  reg [31:0] read_value;
  reg [15:0] access_error;
  always @(posedge sample_clk) begin
    if (histogram_clearing)
      histogram[histogram_clear_address] <= 0;
    else if (event_valid && control[1] && event_good)
      histogram[event_tap] <= histogram[event_tap] + 1'b1;
  end

  always @* begin
    read_value = 0;
    access_error = 0;
    if (addr[1:0] != 0) access_error = 16'd3;
    else if (addr >= 16'h1000 && addr < 16'h1000 + TAPS*4)
      read_value = {16'd0, calib_rd_data};
    else if (addr >= 16'h4000 && addr < 16'h4000 + TAPS*4)
      read_value = histogram[addr[TAP_WIDTH+1:2]];
    else case (addr)
      16'h0000: read_value = 32'h54444301;
      16'h0004: read_value = {29'd0, control};
      16'h0008: read_value = {26'd0, armed_sync[2], histogram_clearing,
                            control[1], control[0], calibration_valid, reference_ready};
      16'h000c: read_value = {{16{phase_offset_10ps[15]}}, phase_offset_10ps};
      16'h0010: read_value = measured_count;
      16'h0014: read_value = invalid_count;
      16'h0018: read_value = overflow_count;
      16'h001c: read_value = bubble_count;
      16'h0020: read_value = last_phase;
      16'h0024: read_value = last_raw;
      16'h0028: read_value = last_epoch;
      16'h002c: read_value = histogram_count;
      16'h0030: read_value = monitor_snapshot[31:0];
      16'h0034: read_value = monitor_snapshot[63:32];
      16'h0038: read_value = monitor_snapshot[95:64];
      16'h003c: read_value = monitor_snapshot[127:96];
      16'h0040: read_value = monitor_snapshot[159:128];
      16'h0044: read_value = monitor_snapshot[191:160];
      16'h0048: read_value = monitor_snapshot[223:192];
      16'h004c: read_value = monitor_snapshot[255:224];
      16'h0050: read_value = written_count;
      16'h0054: read_value = calibration_revision;
      16'h0058: read_value = 0;
      16'h005c: read_value = {TAPS[15:0], 8'd16, 8'd64};
      default: access_error = 16'd3;
    endcase
    if (histogram_clearing && addr >= 16'h4000 && addr < 16'h4000 + TAPS*4)
      access_error = 16'd4;
  end

  always @(posedge sample_clk or negedge sample_rst_n) begin
    if (!sample_rst_n) begin
      request_sync <= 0; armed_sync <= 0; monitor_sync <= 0;
      request_meta <= 0; request_data <= 0;
      monitor_meta <= 0; monitor_sampled <= 0; monitor_snapshot <= 0;
      monitor_seen <= 0; ack_toggle <= 0; response_hold <= 0;
      control <= 0; calibration_valid <= 0; phase_offset_10ps <= 0;
      clear_statistics_toggle <= 0; written_count <= 0; previous_entry <= 0;
      calibration_revision <= 0; calib_wr_en <= 0;
      calib_wr_addr <= 0; calib_wr_data <= 0;
      histogram_clearing <= 1; histogram_clear_address <= 0;
      measured_count <= 0; invalid_count <= 0; overflow_count <= 0;
      bubble_count <= 0; histogram_count <= 0;
      last_epoch <= 0; last_phase <= 0; last_raw <= 0;
    end else begin
      request_sync <= {request_sync[1:0], request_toggle};
      request_meta <= request_hold;
      request_data <= request_meta;
      armed_sync <= {armed_sync[1:0], armed_dac};
      monitor_sync <= {monitor_sync[1:0], monitor_toggle};
      monitor_meta <= monitor_data;
      monitor_sampled <= monitor_meta;
      if (monitor_sync[2] != monitor_seen) begin
        monitor_seen <= monitor_sync[2];
        monitor_snapshot <= monitor_sampled;
      end
      calib_wr_en <= 0;
      if (histogram_clearing) begin
        if (histogram_clear_address == TAPS-1) histogram_clearing <= 0;
        else histogram_clear_address <= histogram_clear_address + 1'b1;
      end
      if (event_valid) begin
        measured_count <= measured_count + 1'b1;
        last_phase <= {21'd0, event_phase_10ps};
        last_epoch <= event_epoch;
        last_raw <= {13'd0, event_bubble, event_overflow, event_good, {(16-TAP_WIDTH){1'b0}}, event_tap};
        if (!event_good) invalid_count <= invalid_count + 1'b1;
        if (event_overflow) overflow_count <= overflow_count + 1'b1;
        if (event_bubble) bubble_count <= bubble_count + 1'b1;
        if (control[1] && !histogram_clearing && event_good) begin
          histogram_count <= histogram_count + 1'b1;
        end
      end

      if (request_sync[2] != ack_toggle) begin
        ack_toggle <= request_sync[2];
        response_hold <= {access_error, read_value};
        if (wr && access_error == 0) begin
          if (armed_sync[2] || (control[0] && addr != 16'h0004))
            response_hold <= {16'd4, 32'd0};
          else if (addr >= 16'h1000 && addr < 16'h1000 + TAPS*4) begin
            if (data > 32'd600 ||
                (lut_index != 0 &&
                 ({1'b0, lut_index} != written_count || data[15:0] < previous_entry)))
              response_hold <= {16'd3, 32'd0};
            else begin
              calib_wr_en <= 1;
              calib_wr_addr <= lut_index;
              calib_wr_data <= data[15:0];
              calibration_valid <= 0;
              previous_entry <= data[15:0];
              written_count <= {1'b0, lut_index} + 1'b1;
              response_hold <= {16'd0, data};
            end
          end else case (addr)
            16'h0004: begin
              if (data[31:3] != 0 || (data[0] &&
                  (!calibration_valid || !reference_ready || data[1] || histogram_clearing)))
                response_hold <= {16'd3, 32'd0};
              else begin control <= data[2:0]; response_hold <= {16'd0, data}; end
            end
            16'h000c: begin
              if ($signed(data) < -32'sd1999 || $signed(data) > 32'sd1999)
                response_hold <= {16'd3, 32'd0};
              else begin phase_offset_10ps <= data[15:0]; response_hold <= {16'd0, data}; end
            end
            16'h0058: begin
              if (data == 32'd1 && !histogram_clearing) begin
                histogram_clearing <= 1; histogram_clear_address <= 0;
                measured_count <= 0; invalid_count <= 0; overflow_count <= 0;
                bubble_count <= 0; histogram_count <= 0;
                clear_statistics_toggle <= !clear_statistics_toggle;
              end else if (data == 32'd2 && written_count == TAPS && !control[1]) begin
                calibration_valid <= 1;
                calibration_revision <= calibration_revision + 1'b1;
              end else if (data == 32'd4) begin
                calibration_valid <= 0; written_count <= 0;
              end else response_hold <= {16'd3, 32'd0};
            end
            default: response_hold <= {16'd3, 32'd0};
          endcase
        end
      end
    end
  end
endmodule
`default_nettype wire
