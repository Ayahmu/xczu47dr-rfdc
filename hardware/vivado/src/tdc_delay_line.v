`timescale 1ns/1ps
`default_nettype none

// TDC delay line using CARRY8 primitives for sub-nanosecond time measurement.
//
// Generates a tapped delay line with TAPS output nodes, each delayed by one
// CARRY8 propagation time (~20-40 ps depending on speed grade and PVT).  The
// carry signal propagates through the chain; all taps are sampled simultaneously
// by the sampling clock to produce a thermometer code that encodes the arrival
// time of signal_in relative to the sample edge.
//
// CRITICAL: This module requires manual LOC constraints to place all CARRY8
// instances in a single vertical column of adjacent slices.  Without LOC, routing
// delays dominate and resolution degrades to hundreds of picoseconds.  See the
// accompanying XDC file for placement constraints.

module tdc_delay_line #(
    parameter TAPS = 256   // Must be a multiple of 8 (one CARRY8 = 8 taps)
)(
    input  wire             signal_in,
    output wire [TAPS-1:0]  taps_out
);

  // Carry chain: [0] is the input, [1..TAPS] are the tap outputs
  (* DONT_TOUCH = "TRUE" *)
  wire [TAPS:0] carry;
  wire [TAPS-1:0] carry_xor_unused;

  assign carry[0] = signal_in;
  assign taps_out = carry[TAPS:1];

  genvar i;
  generate
    for (i = 0; i < TAPS/8; i = i + 1) begin : carry_block
      // DONT_TOUCH prevents synthesis from optimizing away the delay chain
      (* DONT_TOUCH = "TRUE" *)
      CARRY8 #(
          .CARRY_TYPE("SINGLE_CY8")
      ) u_carry8 (
          // CO[7:0] are the 8 delayed outputs
          .CO     (carry[i*8+8:i*8+1]),
          // CI is the input to this block (output of previous block or signal_in)
          .CI     (carry[i*8]),
          .CI_TOP (1'b0),
          // S=1 selects the preceding carry; DI=0 prevents forced-high taps.
          .DI     (8'h00),
          .S      (8'hFF),
          .O      (carry_xor_unused[i*8+7:i*8])
      );
    end
  endgenerate

  // Verification aid: check parameter at elaboration time
  initial begin
    if (TAPS % 8 != 0) begin
      $error("TDC_DELAY_LINE: TAPS must be a multiple of 8");
      $finish;
    end
  end

endmodule

`default_nettype wire
