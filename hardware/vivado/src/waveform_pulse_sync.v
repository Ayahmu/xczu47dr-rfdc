`timescale 1ns/1ps

// Toggle-based one-shot CDC. A source pulse changes one bit; the destination
// observes the change through a two-flop synchronizer and emits one local
// clock pulse. No pulse width assumption crosses the clock boundary.
module waveform_pulse_sync (
    input wire src_clk, input wire src_rst_n, input wire src_pulse,
    input wire dst_clk, input wire dst_rst_n, output wire dst_pulse
);
  reg src_toggle;
  (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [1:0] dst_sync;
  reg dst_seen;
  always @(posedge src_clk or negedge src_rst_n) begin
    if (!src_rst_n) src_toggle <= 1'b0;
    else if (src_pulse) src_toggle <= ~src_toggle;
  end
  always @(posedge dst_clk or negedge dst_rst_n) begin
    if (!dst_rst_n) begin
      dst_sync <= 2'b00;
      dst_seen <= 1'b0;
    end else begin
      dst_sync <= {dst_sync[0], src_toggle};
      dst_seen <= dst_sync[1];
    end
  end
  assign dst_pulse = dst_sync[1] ^ dst_seen;
endmodule
