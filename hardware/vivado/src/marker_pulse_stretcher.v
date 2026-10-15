`timescale 1ns/1ps
// Registers a one-cycle marker and holds it high for WIDTH cycles so that it
// survives a level shifter and a cable to another instrument.  A marker that
// arrives while the output is high restarts the count.
module marker_pulse_stretcher #(
    parameter integer WIDTH = 50
) (
    input  wire clk,
    input  wire rst_n,
    input  wire marker,
    output reg  out
);
  localparam integer COUNT_BITS = $clog2(WIDTH + 1);
  reg [COUNT_BITS-1:0] remaining;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      remaining <= {COUNT_BITS{1'b0}};
      out <= 1'b0;
    end else if (marker) begin
      remaining <= WIDTH - 1;
      out <= 1'b1;
    end else if (remaining != 0) begin
      remaining <= remaining - 1'b1;
    end else begin
      out <= 1'b0;
    end
  end
endmodule
