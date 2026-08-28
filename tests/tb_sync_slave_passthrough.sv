`timescale 1ns/1ps

module tb_sync_slave_passthrough;
  reg clk = 1'b0;
  reg mclk = 1'b0;
  reg rst_n = 1'b0;
  reg sync_in = 1'b0;
  wire hmc_sync;
  wire slave_sync;

  always #5 clk = ~clk;
  always #50 mclk = ~mclk;

  sync_role_control #(
      .IS_MASTER(0),
      .WAIT_CYCLES(3),
      .HIGH_CYCLES(2)
  ) dut (
      .clk(clk),
      .mclk(mclk),
      .rst_n(rst_n),
      .sync_request(1'b0),
      .sync_in(sync_in),
      .role_master(1'b0),
      .sync_bypass(1'b0),
      .hmc_sync(hmc_sync),
      .slave_sync(slave_sync),
      .sync_done()
  );

  initial begin
    #23 rst_n = 1'b1;

    // Change XS20 away from both clock edges. The HMC7044 pin must follow
    // without waiting for the next 10 MHz mclk edge.
    #14 sync_in = 1'b1;
    #1;
    if (hmc_sync !== 1'b1) begin
      $display("FAIL: slave XS20 rising edge waited for mclk");
      $finish;
    end

    #17 sync_in = 1'b0;
    #1;
    if (hmc_sync !== 1'b0) begin
      $display("FAIL: slave XS20 falling edge waited for mclk");
      $finish;
    end
    if (slave_sync !== 1'b0) begin
      $display("FAIL: slave unexpectedly drove the XS20 output");
      $finish;
    end

    $display("PASS: slave XS20 reaches HMC7044 without FPGA mclk re-timing");
    $finish;
  end
endmodule
