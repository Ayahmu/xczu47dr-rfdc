`timescale 1ns/1ps
`default_nettype none

// Carry-chain TDC sampled at 200 MHz. The asynchronous trigger drives the
// delay line directly so its sub-cycle arrival phase is preserved.
module tdc_core #(
    parameter integer TAPS = 256,
    parameter integer CALIB_ADDR_WIDTH = 10,
    parameter integer INDEX_WIDTH = $clog2(TAPS)
) (
    input  wire                         clk_sample_200mhz,
    input  wire                         rst_n,
    input  wire                         trigger_in,
    input  wire                         calib_wr_en,
    input  wire [CALIB_ADDR_WIDTH-1:0]  calib_wr_addr,
    input  wire [15:0]                  calib_wr_data,
    output reg  [15:0]                  phase_ps_x10,
    output reg                          phase_valid,
    output reg                          phase_overflow,
    output reg                          phase_metastable,
    output reg  [1:0]                   phase_slot,
    output reg  [INDEX_WIDTH-1:0]       tap_index_raw_dbg,
    output reg                          measurement_toggle
);

  wire [TAPS-1:0] delay_samples;
  reg [1:0] coarse_slot;
  wire [1:0] delay_sample_slot = coarse_slot;

  always @(posedge clk_sample_200mhz or negedge rst_n) begin
    if (!rst_n) begin
      coarse_slot <= 2'd0;
    end else begin
      coarse_slot <= coarse_slot + 2'd1;
    end
  end

  tdc_delay_line #(
      .TAPS(TAPS)
  ) u_delay_line (
      .signal_in(trigger_in),
      .taps_out (delay_samples)
  );

  wire [INDEX_WIDTH-1:0] encoded_tap;
  wire [1:0] encoded_slot;
  wire encoded_valid;
  wire encoded_overflow;
  wire encoded_metastable;

  tdc_encoder #(
      .TAPS(TAPS),
      .SLOT_WIDTH(2),
      .INDEX_WIDTH(INDEX_WIDTH)
  ) u_encoder (
      .clk_sample     (clk_sample_200mhz),
      .rst_n          (rst_n),
      .taps_in        (delay_samples),
      .sample_slot_in (delay_sample_slot),
      .tap_index      (encoded_tap),
      .sample_slot_out(encoded_slot),
      .valid          (encoded_valid),
      .overflow       (encoded_overflow),
      .metastable     (encoded_metastable)
  );

  wire [15:0] calibrated_time;
  wire calibrated_valid;

  tdc_calibrator #(
      .TAPS(TAPS),
      .CALIB_ADDR_WIDTH(CALIB_ADDR_WIDTH)
  ) u_calibrator (
      .clk            (clk_sample_200mhz),
      .rst_n          (rst_n),
      .tap_index_raw  (encoded_tap),
      .valid_in       (encoded_valid),
      .calib_wr_en    (calib_wr_en),
      .calib_wr_addr  (calib_wr_addr),
      .calib_wr_data  (calib_wr_data),
      .time_ps_x10    (calibrated_time),
      .valid_out      (calibrated_valid)
  );

  reg [1:0] valid_slot_pipeline;
  reg [INDEX_WIDTH-1:0] valid_tap_pipeline;

  always @(posedge clk_sample_200mhz or negedge rst_n) begin
    if (!rst_n) begin
      phase_ps_x10 <= 16'd0;
      phase_valid <= 1'b0;
      phase_overflow <= 1'b0;
      phase_metastable <= 1'b0;
      phase_slot <= 2'd0;
      tap_index_raw_dbg <= {INDEX_WIDTH{1'b0}};
      measurement_toggle <= 1'b0;
      valid_slot_pipeline <= 2'd0;
      valid_tap_pipeline <= {INDEX_WIDTH{1'b0}};
    end else begin
      if (encoded_valid) begin
        valid_slot_pipeline <= encoded_slot;
        valid_tap_pipeline <= encoded_tap;
      end

      if (calibrated_valid) begin
        phase_ps_x10 <= calibrated_time;
        phase_valid <= 1'b1;
        phase_overflow <= 1'b0;
        phase_metastable <= 1'b0;
        phase_slot <= valid_slot_pipeline;
        tap_index_raw_dbg <= valid_tap_pipeline;
        measurement_toggle <= ~measurement_toggle;
      end else if (encoded_overflow) begin
        phase_valid <= 1'b0;
        phase_overflow <= 1'b1;
        phase_metastable <= 1'b0;
        phase_slot <= encoded_slot;
        tap_index_raw_dbg <= encoded_tap;
        measurement_toggle <= ~measurement_toggle;
      end else if (encoded_metastable) begin
        phase_valid <= 1'b0;
        phase_overflow <= 1'b0;
        phase_metastable <= 1'b1;
        phase_slot <= encoded_slot;
        tap_index_raw_dbg <= encoded_tap;
        measurement_toggle <= ~measurement_toggle;
      end
    end
  end

endmodule

`default_nettype wire
