`timescale 1ns/1ps

module tb_sync_role_switch;
  reg clk = 1'b0;
  reg rst_n = 1'b0;
  reg master_request = 1'b0;
  reg master_role = 1'b1;
  reg slave_role = 1'b0;
  wire master_hmc_sync;
  wire master_slave_sync;
  wire slave_hmc_sync;
  wire master_sync_done;
  wire slave_sync_done;

  always #5 clk = ~clk;

  sync_role_control #(
      .IS_MASTER(1),
      .WAIT_CYCLES(3),
      .HIGH_CYCLES(2)
  ) master_i (
      .clk(clk),
      .rst_n(rst_n),
      .sync_request(master_request),
      .sync_in(1'b0),
      .role_master(master_role), .sync_bypass(1'b0),
      .hmc_sync(master_hmc_sync),
      .slave_sync(master_slave_sync),
      .sync_done(master_sync_done)
  );

  sync_role_control #(
      .IS_MASTER(0),
      .WAIT_CYCLES(3),
      .HIGH_CYCLES(2)
  ) slave_i (
      .clk(clk),
      .rst_n(rst_n),
      .sync_request(1'b0),
      .sync_in(master_slave_sync),
      .role_master(slave_role), .sync_bypass(1'b0),
      .hmc_sync(slave_hmc_sync),
      .slave_sync(),
      .sync_done(slave_sync_done)
  );

  integer master_rises = 0;
  integer slave_rises = 0;
  integer master_done_pulses = 0;
  integer slave_done_pulses = 0;
  reg master_hmc_d = 1'b0;
  reg slave_hmc_d = 1'b0;
  reg master_done_d = 1'b0;
  reg slave_done_d = 1'b0;

  always @(posedge clk) begin
    master_hmc_d <= master_hmc_sync;
    slave_hmc_d <= slave_hmc_sync;
    master_done_d <= master_sync_done;
    slave_done_d <= slave_sync_done;
    if (master_hmc_sync && !master_hmc_d)
      master_rises <= master_rises + 1;
    if (slave_hmc_sync && !slave_hmc_d)
      slave_rises <= slave_rises + 1;
    if (master_sync_done && !master_done_d)
      master_done_pulses <= master_done_pulses + 1;
    if (slave_sync_done && !slave_done_d)
      slave_done_pulses <= slave_done_pulses + 1;
  end

  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);
    master_request = 1'b1;
    @(posedge clk);
    master_request = 1'b0;

    repeat (35) @(posedge clk);
    if (master_rises != 1) begin
      $display("FAIL: master generated %0d sync pulses, expected 1", master_rises);
      $finish;
    end
    if (slave_rises != 1) begin
      $display("FAIL: slave observed %0d sync pulses, expected 1", slave_rises);
      $finish;
    end
    if (master_done_pulses != 1) begin
      $display("FAIL: master sync_done pulses=%0d, expected 1", master_done_pulses);
      $finish;
    end
    if (slave_done_pulses != 1) begin
      $display("FAIL: slave sync_done pulses=%0d, expected 1", slave_done_pulses);
      $finish;
    end

    $display("PASS: runtime roles generate and receive a single-pulse sync sequence");
    $finish;
  end
endmodule
