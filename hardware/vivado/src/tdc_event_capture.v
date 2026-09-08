`timescale 1ns/1ps
`default_nettype none

// Event timestamps relative to the native 50 MHz DAC beat counter.
// ref_epoch names the DAC rising edge preceding ref_toggle's falling edge.
// The 200 MHz clock must be phase aligned with the DAC clock. Its falling
// edge samples the reference halfway between common rising clock edges.
(* KEEP_HIERARCHY = "TRUE" *)
module tdc_event_capture #(
    parameter integer TAPS = 2048,
    parameter integer DEFAULT_TAP_PS = 0,
    parameter integer TAP_WIDTH = $clog2(TAPS)
) (
    input  wire        sample_clk,
    input  wire        rst_n,
    input  wire        trigger_in,
    input  wire        ref_toggle,
    input  wire [31:0] ref_epoch,
    input  wire        calib_wr_en,
    input  wire [TAP_WIDTH-1:0] calib_wr_addr,
    input  wire [15:0] calib_wr_data,
    input  wire [TAP_WIDTH-1:0] calib_rd_addr,
    output wire [15:0] calib_rd_data, // Asynchronous table readback.
    output reg         ready,
    output reg         event_valid,
    output reg         event_good,
    output reg         event_overflow,
    output reg         event_bubble,
    output reg  [31:0] event_epoch,
    output reg  [10:0] event_phase_10ps,
    output reg  [TAP_WIDTH-1:0] event_tap
);
  localparam integer GROUPS = TAPS / 8;
  localparam integer GROUP_BITS = $clog2(GROUPS);

  reg ref_toggle_half;
  reg [31:0] ref_epoch_half;
  reg ref_seen;
  reg [1:0] next_slot;
  reg [31:0] next_epoch;
  wire ref_changed = ref_toggle_half != ref_seen;
  wire [1:0] capture_slot = ref_changed ? 2'd3 : next_slot;
  wire [31:0] capture_epoch = ref_changed ? ref_epoch_half : next_epoch;

  always @(negedge sample_clk or negedge rst_n) begin
    if (!rst_n) begin
      ref_toggle_half <= 1'b0;
      ref_epoch_half <= 32'd0;
    end else begin
      ref_toggle_half <= ref_toggle;
      ref_epoch_half <= ref_epoch;
    end
  end

  always @(posedge sample_clk or negedge rst_n) begin
    if (!rst_n) begin
      ready <= 1'b0;
      ref_seen <= 1'b0;
      next_slot <= 2'd0;
      next_epoch <= 32'd0;
    end else if (ref_changed) begin
      ready <= 1'b1;
      ref_seen <= ref_toggle_half;
      next_slot <= 2'd0;
      next_epoch <= ref_epoch_half + 32'd1;
    end else if (ready) begin
      next_slot <= next_slot + 2'd1;
      if (next_slot == 2'd3) begin
        ready <= 1'b0;
        next_epoch <= next_epoch + 32'd1;
      end
    end
  end

  (* DONT_TOUCH = "TRUE" *) wire [TAPS:0] carry;
  wire [TAPS-1:0] unused_xor;
  wire [TAPS-1:0] sampled;
  wire [TAPS-1:0] filtered;
  assign filtered[0] = sampled[0];
  assign filtered[TAPS-1] = sampled[TAPS-1];
  assign carry[0] = trigger_in;
  genvar g;
  generate
    for (g = 1; g < TAPS-1; g = g + 1) begin : bubble_filter
      assign filtered[g] = (sampled[g-1] & sampled[g]) |
                           (sampled[g] & sampled[g+1]) |
                           (sampled[g-1] & sampled[g+1]);
    end
    for (g = 0; g < GROUPS; g = g + 1) begin : carry_block
      (* DONT_TOUCH = "TRUE" *) CARRY8 #(.CARRY_TYPE("SINGLE_CY8")) u_carry8 (
          .CI(carry[g*8]), .CI_TOP(1'b0), .DI(8'h00), .S(8'hff),
          .CO(carry[g*8+8:g*8+1]), .O(unused_xor[g*8+7:g*8])
      );
    end
    for (g = 0; g < TAPS; g = g + 1) begin : sample_bit
      (* DONT_TOUCH = "TRUE" *) FDRE #(.INIT(1'b0)) u_sample_ff (
          .C(sample_clk), .CE(1'b1), .D(carry[g+1]), .R(!rst_n), .Q(sampled[g])
      );
    end
  endgenerate

  reg [1:0] slot_s1;
  reg [31:0] epoch_s1;
  reg ready_s1;
  always @(posedge sample_clk or negedge rst_n) begin
    if (!rst_n) begin
      slot_s1 <= 2'd0;
      epoch_s1 <= 32'd0;
      ready_s1 <= 1'b0;
    end else begin
      slot_s1 <= capture_slot;
      epoch_s1 <= capture_epoch;
      ready_s1 <= ready || ref_changed;
    end
  end

  // Encode each eight-tap group before the global reduction. This is a
  // pipelined one-hot OR encoder, not a 1024-way combinational priority chain.
  reg [GROUPS-1:0] group_nonzero;
  reg [GROUPS-1:0] group_full;
  reg [GROUPS-1:0] group_bad;
  reg [GROUPS-1:0] group_boundary;
  reg [2:0] group_index [0:GROUPS-1];
  reg head_s2;
  reg [1:0] slot_s2;
  reg [31:0] epoch_s2;
  reg ready_s2;
  wire [TAPS:0] sampled_extended = {1'b0, filtered};
  generate
    for (g = 0; g < GROUPS; g = g + 1) begin : group_encoder
      wire [7:0] bits_local = filtered[g*8 +: 8];
      wire [7:0] bits_next = sampled_extended[g*8+1 +: 8];
      wire [7:0] boundary = bits_local & ~bits_next;
      always @(posedge sample_clk or negedge rst_n) begin
        if (!rst_n) begin
          group_nonzero[g] <= 1'b0;
          group_full[g] <= 1'b0;
          group_bad[g] <= 1'b0;
          group_boundary[g] <= 1'b0;
          group_index[g] <= 3'd0;
        end else begin
          group_nonzero[g] <= |bits_local;
          group_full[g] <= &bits_local;
          group_bad[g] <= |(~bits_local & bits_next);
          group_boundary[g] <= |boundary;
          group_index[g] <= {
              |boundary[7:4],
              |(boundary & 8'hcc),
              |(boundary & 8'haa)
          };
        end
      end
    end
  endgenerate
  always @(posedge sample_clk or negedge rst_n) begin
    if (!rst_n) begin
      head_s2 <= 1'b0;
      slot_s2 <= 2'd0;
      epoch_s2 <= 32'd0;
      ready_s2 <= 1'b0;
    end else begin
      head_s2 <= filtered[0];
      slot_s2 <= slot_s1;
      epoch_s2 <= epoch_s1;
      ready_s2 <= ready_s1;
    end
  end

  integer b;
  integer n;
  reg [GROUP_BITS-1:0] encoded_group;
  reg [2:0] encoded_local;
  always @* begin
    encoded_group = {GROUP_BITS{1'b0}};
    encoded_local = 3'd0;
    for (n = 0; n < GROUPS; n = n + 1) begin
      if (group_boundary[n]) begin
        encoded_local = encoded_local | group_index[n];
      end
      for (b = 0; b < GROUP_BITS; b = b + 1) begin
        if ((n & (1 << b)) != 0)
          encoded_group[b] = encoded_group[b] | group_boundary[n];
      end
    end
  end
  wire sample_zero = !(|group_nonzero);
  wire sample_full = &group_full;
  wire sample_bad = !head_s2 || (|group_bad);
  wire [TAP_WIDTH-1:0] decoded_tap = {encoded_group, encoded_local};
  reg armed;
  reg valid_s3;
  reg good_s3;
  reg overflow_s3;
  reg bubble_s3;
  reg [TAP_WIDTH-1:0] tap_s3;
  reg [1:0] slot_s3;
  reg [31:0] epoch_s3;

  always @(posedge sample_clk or negedge rst_n) begin
    if (!rst_n) begin
      armed <= 1'b1;
      valid_s3 <= 1'b0;
      good_s3 <= 1'b0;
      overflow_s3 <= 1'b0;
      bubble_s3 <= 1'b0;
      tap_s3 <= 0;
      slot_s3 <= 2'd0;
      epoch_s3 <= 32'd0;
    end else begin
      valid_s3 <= 1'b0;
      if (sample_zero)
        armed <= 1'b1;
      else if (armed && ready_s2) begin
        armed <= 1'b0;
        valid_s3 <= 1'b1;
        good_s3 <= !sample_full && !sample_bad;
        overflow_s3 <= sample_full;
        bubble_s3 <= !sample_full && sample_bad;
        tap_s3 <= sample_bad ? {TAP_WIDTH{1'b0}} : decoded_tap;
        slot_s3 <= slot_s2;
        epoch_s3 <= epoch_s2;
      end
    end
  end

  // The initial table is diagnostic only. The controller must require a
  // measured calibration table and explicit commit before enabling correction.
  (* ram_style = "distributed" *) reg [15:0] calibration [0:TAPS-1];
  integer i;
  initial begin
    for (i = 0; i < TAPS; i = i + 1)
      calibration[i] = DEFAULT_TAP_PS > 0 ? ((i + 1) * DEFAULT_TAP_PS) / 10 : ((i + 1) * 500) / TAPS;
  end
  assign calib_rd_data = (calib_rd_addr < TAPS) ? calibration[calib_rd_addr] : 16'd0;
  always @(posedge sample_clk) begin
    if (rst_n && calib_wr_en && calib_wr_addr < TAPS)
      calibration[calib_wr_addr] <= calib_wr_data;
  end

  reg valid_s4;
  reg good_s4;
  reg overflow_s4;
  reg bubble_s4;
  reg [TAP_WIDTH-1:0] tap_s4;
  reg [10:0] slot_time_s4;
  reg [31:0] epoch_s4;
  reg [15:0] fine_s4;
  always @(posedge sample_clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s4 <= 1'b0;
      good_s4 <= 1'b0;
      overflow_s4 <= 1'b0;
      bubble_s4 <= 1'b0;
      tap_s4 <= 0;
      slot_time_s4 <= 11'd0;
      epoch_s4 <= 32'd0;
      fine_s4 <= 16'd0;
    end else begin
      valid_s4 <= valid_s3;
      good_s4 <= good_s3;
      overflow_s4 <= overflow_s3;
      bubble_s4 <= bubble_s3;
      tap_s4 <= tap_s3;
      epoch_s4 <= epoch_s3;
      fine_s4 <= calibration[tap_s3];
      case (slot_s3)
        2'd0: slot_time_s4 <= 11'd0;
        2'd1: slot_time_s4 <= 11'd500;
        2'd2: slot_time_s4 <= 11'd1000;
        2'd3: slot_time_s4 <= 11'd1500;
      endcase
    end
  end

  wire signed [17:0] phase_difference =
      $signed({7'd0, slot_time_s4}) - $signed({2'd0, fine_s4});
  wire signed [17:0] phase_wrapped = phase_difference + 18'sd2000;
  wire calibration_in_range = fine_s4 <= 16'd600;
  always @(posedge sample_clk or negedge rst_n) begin
    if (!rst_n) begin
      event_valid <= 1'b0;
      event_good <= 1'b0;
      event_overflow <= 1'b0;
      event_bubble <= 1'b0;
      event_epoch <= 32'd0;
      event_phase_10ps <= 11'd0;
      event_tap <= 0;
    end else begin
      event_valid <= valid_s4;
      if (valid_s4) begin
        event_good <= good_s4 && calibration_in_range && ready;
        event_overflow <= overflow_s4 || (good_s4 && !calibration_in_range);
        event_bubble <= bubble_s4;
        event_tap <= tap_s4;
        if (good_s4 && calibration_in_range) begin
          event_epoch <= phase_difference < 0 ? epoch_s4 - 32'd1 : epoch_s4;
          event_phase_10ps <= phase_difference < 0 ? phase_wrapped[10:0] : phase_difference[10:0];
        end else begin
          event_epoch <= epoch_s4;
          event_phase_10ps <= 11'd0;
        end
      end
    end
  end

  initial begin
    if (TAPS < 16 || TAPS > 2048 || (TAPS & (TAPS - 1)) != 0) begin
      $error("TDC_EVENT_CAPTURE requires a power-of-two TAPS from 16 to 2048");
      $finish;
    end
  end
endmodule
`default_nettype wire
