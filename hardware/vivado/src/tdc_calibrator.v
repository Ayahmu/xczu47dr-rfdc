`timescale 1ns/1ps

// TDC calibration table: converts raw tap index to calibrated time in picoseconds.
//
// Each tap in the delay line has slightly different propagation delay due to
// process variation and routing.  The calibration table stores the cumulative
// delay at each tap, measured during a startup calibration routine.  This module
// performs the table lookup and outputs calibrated time.
//
// The table is writable via AXI registers (not implemented here - just the lookup).
// Units: tap_delay_table[i] is in units of 10 ps, range 0-65535 (0-655 ns).

module tdc_calibrator #(
    parameter TAPS = 256,
    parameter CALIB_ADDR_WIDTH = 10  // 1024 words, use lower 256 for tap table
)(
    input  wire                          clk,
    input  wire                          rst_n,
    // Raw tap index from encoder
    input  wire [$clog2(TAPS)-1:0]       tap_index_raw,
    input  wire                          valid_in,
    // Calibration table write port (from AXI registers)
    input  wire                          calib_wr_en,
    input  wire [CALIB_ADDR_WIDTH-1:0]   calib_wr_addr,
    input  wire [15:0]                   calib_wr_data,
    // Calibrated output
    output reg  [15:0]                   time_ps_x10,  // time in units of 10ps
    output reg                           valid_out
);

  // Calibration table: BRAM, 256 entries × 16 bits
  // Entry [i] = cumulative delay to tap i, in units of 10 ps
  reg [15:0] tap_delay_table [0:TAPS-1];

  // Initialize to linear approximation: 30 ps per tap = 3 units of 10ps
  integer i;
  initial begin
    for (i = 0; i < TAPS; i = i + 1) begin
      tap_delay_table[i] = i * 3;  // 30 ps = 3 × 10ps
    end
  end

  // Write port for calibration updates
  always @(posedge clk) begin
    if (calib_wr_en && calib_wr_addr < TAPS) begin
      tap_delay_table[calib_wr_addr] <= calib_wr_data;
    end
  end

  // Read port: lookup tap_index_raw in the table (combinational read, registered output)
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      time_ps_x10 <= 16'd0;
      valid_out   <= 1'b0;
    end else begin
      valid_out <= valid_in;
      if (valid_in && tap_index_raw < TAPS) begin
        time_ps_x10 <= tap_delay_table[tap_index_raw];
      end
    end
  end

endmodule
