`timescale 1ns/1ps

// Verifies that the master SYNC rising edge is registered to the HMC7044
// 10 MHz monitor clock (mclk).  Because mclk is phase-deterministic relative
// to the HMC7044 VCXO, this alignment makes the HMC7044 multichip-sync
// divider re-seed deterministic across repeated sync() requests instead of a
// random integer-VCO-cycle offset.  Two requests are issued at different
// pl_clk phases and both SYNC edges must land on mclk rising edges.
module tb_sync_deterministic;
  reg clk = 1'b0;   // pl_clk, 100 MHz (10 ns period)
  reg mclk = 1'b0;  // HMC7044 monitor, 10 MHz (100 ns period)
  reg rst_n = 1'b0;
  reg request = 1'b0;
  wire hmc_sync;
  wire sync_done;

  always #5 clk = ~clk;
  always #50 mclk = ~mclk;

  sync_role_control #(
      .IS_MASTER(1),
      .WAIT_CYCLES(3),
      .HIGH_CYCLES(2)
  ) dut (
      .clk(clk),
      .mclk(mclk),
      .rst_n(rst_n),
      .sync_request(request),
      .sync_in(1'b0),
      .role_master(1'b1),
      .sync_bypass(1'b0),
      .hmc_sync(hmc_sync),
      .slave_sync(),
      .sync_done(sync_done)
  );

  integer rise_count = 0;
  integer rise_time [0:3];
  reg hmc_d = 1'b0;
  always @(posedge mclk) begin
    hmc_d <= hmc_sync;
    if (hmc_sync && !hmc_d) begin
      rise_time[rise_count] = $time;
      rise_count <= rise_count + 1;
    end
  end

  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // First request at an arbitrary pl_clk phase.
    request = 1'b1;
    @(posedge clk);
    request = 1'b0;
    while (rise_count < 1) @(posedge mclk);

    // Second request shifted by half a monitor-clock period.
    repeat (5) @(posedge clk);
    request = 1'b1;
    @(posedge clk);
    request = 1'b0;
    while (rise_count < 2) @(posedge mclk);

    repeat (2) @(posedge mclk);

    // mclk rising edges occur at 50, 150, 250, ... ns.  A registered SYNC
    // edge therefore must satisfy (t - 50) % 100 == 0.
    if (((rise_time[0] - 50) % 100) != 0 ||
        ((rise_time[1] - 50) % 100) != 0) begin
      $display("FAIL: SYNC edges not aligned to monitor clock: t0=%0d t1=%0d",
               rise_time[0], rise_time[1]);
      $finish;
    end
    $display("PASS: deterministic SYNC edges are registered to the HMC7044 monitor clock");
    $finish;
  end
endmodule
