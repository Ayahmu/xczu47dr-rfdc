`timescale 1ns/1ps

// Verifies that the master SYNC sequencer emits one clean single pulse in the
// pl_clk domain and drives it directly to the HMC7044 SYNC pin.  The old
// FPGA-side mclk re-timing was removed: SYNC is no longer re-timed to the
// HMC7044 monitor clock, so the sequencer simply waits WAIT_CYCLES, asserts
// hmc_sync for HIGH_CYCLES, deasserts it, and emits one sync_done pulse.
module tb_sync_deterministic;
  reg clk = 1'b0;   // pl_clk, 100 MHz (10 ns period)
  reg rst_n = 1'b0;
  reg request = 1'b0;
  wire hmc_sync;
  wire sync_done;

  always #5 clk = ~clk;

  sync_role_control #(
      .IS_MASTER(1),
      .WAIT_CYCLES(3),
      .HIGH_CYCLES(2)
  ) dut (
      .clk(clk),
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
  integer fall_count = 0;
  integer done_count = 0;
  integer high_cycles = 0;
  reg hmc_d = 1'b0;
  reg done_d = 1'b0;

  always @(posedge clk) begin
    hmc_d <= hmc_sync;
    done_d <= sync_done;
    if (hmc_sync && !hmc_d)
      rise_count <= rise_count + 1;
    if (!hmc_sync && hmc_d)
      fall_count <= fall_count + 1;
    if (sync_done && !done_d)
      done_count <= done_count + 1;
    if (hmc_sync)
      high_cycles <= high_cycles + 1;
  end

  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    request <= 1'b1;
    repeat (2) @(posedge clk);
    request <= 1'b0;

    // WAIT_CYCLES=3 followed by HIGH_CYCLES=2, plus margin.
    repeat (20) @(posedge clk);

    if (rise_count != 1) begin
      $display("FAIL: master generated %0d sync pulses, expected 1", rise_count);
      $finish;
    end
    if (fall_count != 1) begin
      $display("FAIL: master sync fall count=%0d, expected 1", fall_count);
      $finish;
    end
    if (done_count != 1) begin
      $display("FAIL: master sync_done pulses=%0d, expected 1", done_count);
      $finish;
    end
    if (high_cycles != 2) begin
      $display("FAIL: master sync high cycles=%0d, expected 2", high_cycles);
      $finish;
    end

    $display("PASS: master emits one clean single-pulse SYNC directly to HMC7044");
    $finish;
  end
endmodule
