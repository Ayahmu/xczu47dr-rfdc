`timescale 1ns/1ps

// A deterministic 10 ps per-tap transport approximation for digital tests.
// This does not model silicon PVT, routing skew, or metastability.
module CARRY8 #(
    parameter CARRY_TYPE = "SINGLE_CY8"
) (
    input wire CI, CI_TOP,
    input wire [7:0] DI, S,
    output wire [7:0] CO, O
);
  wire [8:0] chain;
  assign chain[0] = CI;
  genvar n;
  generate
    for (n = 0; n < 8; n = n + 1) begin : bit_delay
      assign #0.010 chain[n+1] = S[n] ? chain[n] : DI[n];
      assign CO[n] = chain[n+1];
      assign O[n] = S[n] ^ chain[n];
    end
  endgenerate
endmodule

module FDRE #(
    parameter INIT = 1'b0
) (
    input wire C, CE, D, R,
    output reg Q = INIT
);
  always @(posedge C) begin
    if (R) Q <= 1'b0;
    else if (CE) Q <= D;
  end
endmodule
