`timescale 1ns/1ps
// XS18 carries the first-sample marker to another instrument (e.g. the start
// input of a QICK board behind a TXS0108E level shifter).  A one-cycle pulse
// is too short for that path, so the marker is registered and held high for
// WIDTH cycles; a new marker while high restarts the count.
module tb_marker_pulse_stretcher;
  reg clk = 1'b0; always #10 clk = ~clk;  // 50 MHz, the DAC fabric clock
  reg rst_n = 1'b0;
  reg marker = 1'b0;
  wire out;
  integer failures = 0;
  integer high_cycles;

  marker_pulse_stretcher #(.WIDTH(50)) dut (.clk(clk), .rst_n(rst_n), .marker(marker), .out(out));

  task pulse; begin @(negedge clk); marker = 1'b1; @(negedge clk); marker = 1'b0; end endtask

  task count_high; begin
    high_cycles = 0;
    while (out) begin @(posedge clk); #1; high_cycles = high_cycles + 1; end
  end endtask

  initial begin
    repeat (3) @(posedge clk); #1;
    if (out !== 1'b0) begin $display("FAIL: output not low in reset"); failures = failures + 1; end
    rst_n = 1'b1;

    // One-cycle marker -> exactly WIDTH cycles high, starting one cycle later (registered).
    pulse;
    @(posedge clk); #1;
    if (out !== 1'b1) begin $display("FAIL: output did not go high after a marker"); failures = failures + 1; end
    count_high;
    if (high_cycles != 49) begin $display("FAIL: held %0d cycles after the first, expected 49", high_cycles); failures = failures + 1; end

    // Quiet line stays low.
    repeat (100) begin @(posedge clk); #1; if (out !== 1'b0) begin $display("FAIL: output high without a marker"); failures = failures + 1; end end

    // A second marker 20 cycles into a pulse restarts the count.
    pulse;
    repeat (20) @(posedge clk);
    pulse;
    @(posedge clk); #1;
    count_high;
    if (high_cycles != 49) begin $display("FAIL: retrigger held %0d cycles, expected 49", high_cycles); failures = failures + 1; end

    // Reset clears a pulse in progress.
    pulse;
    @(posedge clk); #1;
    rst_n = 1'b0; @(posedge clk); #1;
    if (out !== 1'b0) begin $display("FAIL: reset did not clear the output"); failures = failures + 1; end

    if (failures == 0) $display("PASS: marker is registered and stretched to WIDTH cycles");
    $finish;
  end
endmodule
