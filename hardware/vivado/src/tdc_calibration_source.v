`timescale 1ns / 1ps
`default_nettype none

// Generate an asynchronous code-density calibration edge.  The TDC samples
// at 200 MHz, while this source runs at a deliberately detuned frequency so
// successive rising edges walk through the complete 5 ns sampling window.
module tdc_calibration_source (
    input  wire async_clk,
    input  wire rst_n,
    output reg  pulse
);
  reg [6:0] period_count;
  always @(posedge async_clk or negedge rst_n) begin
    if (!rst_n) begin
      period_count <= 7'd0;
      pulse <= 1'b0;
    end else begin
      // Four source-clock cycles high, followed by 33 low cycles.
      pulse <= period_count < 7'd4;
      if (period_count == 7'd36) period_count <= 7'd0;
      else period_count <= period_count + 1'b1;
    end
  end
endmodule
`default_nettype wire
