`timescale 1ns/1ps

module tb_dac_trigger_scheduler;
  reg clk = 1'b0;
  reg rst_n = 1'b0;
  reg request = 1'b0;
  reg clear_pending = 1'b0;
  wire launch;
  wire pending;
  integer launch_count = 0;
  integer request_cycle = -1;
  integer launch_cycle = -1;
  integer cycle_count = 0;

  always #10 clk = ~clk; // 50 MHz DAC fabric clock
  always @(posedge clk) begin
    cycle_count = cycle_count + 1;
    if (request)
      request_cycle = cycle_count;
    if (launch) begin
      launch_count = launch_count + 1;
      launch_cycle = cycle_count;
    end
  end

  dac_trigger_scheduler dut (
      .clk(clk), .rst_n(rst_n), .trigger_request(request), .clear_pending(clear_pending),
      .trigger_launch(launch),
      .trigger_pending(pending)
  );

  initial begin
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    // A request is released after a fixed DAC-clock delay, independent of
    // SYSREF's phase.  In particular, it cannot select a different 500 ns
    // SYSREF period on another board.
    repeat (3) @(posedge clk);
    request = 1'b1;
    @(posedge clk);
    request = 1'b0;
    repeat (3) @(posedge clk);
    #1;
    if (launch_count != 0 || !pending) begin
      $display("FAIL: scheduler did not hold request for fixed DAC delay count=%0d pending=%b", launch_count, pending);
      $finish;
    end
    repeat (10) @(posedge clk);
    #1;
    if (launch_count != 1 || pending) begin
      $display("FAIL: launches=%0d pending=%b request_to_launch=%0d cycles",
               launch_count, pending, launch_cycle - request_cycle);
      $finish;
    end
    @(posedge clk);
    #1;
    if (launch) begin
      $display("FAIL: launch pulse was wider than one DAC cycle");
      $finish;
    end
    $display("PASS: DAC trigger uses a fixed DAC delay without SYSREF launch gating");
    $finish;
  end

  initial begin
    #3000;
    $display("FAIL: scheduler test timed out");
    $finish;
  end
endmodule
