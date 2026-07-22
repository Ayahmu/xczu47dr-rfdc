`timescale 1ns / 1ps

module tb_rfctrl2_sync_controller;
  reg ddr_clk = 1'b0;
  reg dac_clk = 1'b0;
  reg ddr_rst_n = 1'b0;
  reg dac_rst_n = 1'b0;
  always #4 ddr_clk = ~ddr_clk;
  always #5 dac_clk = ~dac_clk;

  reg master_arm = 1'b0;
  reg master_abort = 1'b0;
  reg master_epoch = 1'b0;
  reg [63:0] master_epoch_value = 64'd0;
  reg master_start = 1'b0;
  reg [63:0] master_start_tick = 64'd0;
  reg follower_arm = 1'b0;
  reg follower_abort = 1'b0;
  reg follower_start = 1'b0;
  reg [63:0] follower_start_tick = 64'd0;

  wire master_sync_out;
  wire master_play_trigger;
  wire follower_play_trigger;
  wire master_armed;
  wire follower_armed;
  wire [63:0] master_tick;
  wire [63:0] follower_tick;

  rfctrl2_sync_controller #(
    .BOARD_IS_MASTER(1),
    .SYNC_PULSE_CYCLES(4),
    .MASTER_EPOCH_DELAY_CYCLES(2)
  ) master (
    .ddr_clk(ddr_clk), .ddr_rst_n(ddr_rst_n),
    .rfctrl2_arm_pulse(master_arm), .rfctrl2_abort_mute_pulse(master_abort),
    .rfctrl2_sync_epoch_pulse(master_epoch), .rfctrl2_epoch(master_epoch_value),
    .rfctrl2_start_valid(master_start), .rfctrl2_start_tick(master_start_tick),
    .dac_clk(dac_clk), .dac_rst_n(dac_rst_n), .ext_sync_in(1'b0),
    .play_trigger_pulse(master_play_trigger), .play_abort_pulse(),
    .sync_out(master_sync_out), .armed(master_armed), .sync_epoch(),
    .hardware_tick(master_tick), .start_pending()
  );

  rfctrl2_sync_controller #(
    .BOARD_IS_MASTER(0),
    .SYNC_PULSE_CYCLES(4),
    .MASTER_EPOCH_DELAY_CYCLES(2)
  ) follower (
    .ddr_clk(ddr_clk), .ddr_rst_n(ddr_rst_n),
    .rfctrl2_arm_pulse(follower_arm), .rfctrl2_abort_mute_pulse(follower_abort),
    .rfctrl2_sync_epoch_pulse(1'b0), .rfctrl2_epoch(64'd0),
    .rfctrl2_start_valid(follower_start), .rfctrl2_start_tick(follower_start_tick),
    .dac_clk(dac_clk), .dac_rst_n(dac_rst_n), .ext_sync_in(master_sync_out),
    .play_trigger_pulse(follower_play_trigger), .play_abort_pulse(),
    .sync_out(), .armed(follower_armed), .sync_epoch(),
    .hardware_tick(follower_tick), .start_pending()
  );

  integer master_trigger_cycle = -1;
  integer follower_trigger_cycle = -1;
  integer dac_cycle = 0;
  always @(posedge dac_clk) begin
    dac_cycle <= dac_cycle + 1;
    if (master_play_trigger) master_trigger_cycle <= dac_cycle;
    if (follower_play_trigger) follower_trigger_cycle <= dac_cycle;
  end

  task ddr_pulse_master_arm;
    begin
      @(negedge ddr_clk); master_arm = 1'b1;
      @(negedge ddr_clk); master_arm = 1'b0;
    end
  endtask

  task ddr_pulse_follower_arm;
    begin
      @(negedge ddr_clk); follower_arm = 1'b1;
      @(negedge ddr_clk); follower_arm = 1'b0;
    end
  endtask

  initial begin
    repeat (4) @(negedge ddr_clk);
    ddr_rst_n = 1'b1;
    repeat (4) @(negedge dac_clk);
    dac_rst_n = 1'b1;

    ddr_pulse_master_arm();
    ddr_pulse_follower_arm();
    repeat (8) @(posedge dac_clk);
    if (!master_armed || !follower_armed) begin
      $error("RFCTRL2 ARM must reach both DAC domains");
      $finish;
    end

    @(negedge ddr_clk);
    master_epoch_value = 64'd0;
    master_epoch = 1'b1;
    @(negedge ddr_clk);
    master_epoch = 1'b0;
    wait (master_sync_out == 1'b1);
    wait (master_tick == 64'd6 && follower_tick == 64'd6);

    @(negedge ddr_clk);
    master_start_tick = master_tick + 64'd30;
    follower_start_tick = follower_tick + 64'd30;
    master_start = 1'b1;
    follower_start = 1'b1;
    @(negedge ddr_clk);
    master_start = 1'b0;
    follower_start = 1'b0;

    wait (master_trigger_cycle >= 0 && follower_trigger_cycle >= 0);
    if (master_trigger_cycle != follower_trigger_cycle) begin
      $error("master/follower START_AT pulses must share the same DAC edge");
      $finish;
    end

    @(negedge ddr_clk);
    master_abort = 1'b1;
    follower_abort = 1'b1;
    @(negedge ddr_clk);
    master_abort = 1'b0;
    follower_abort = 1'b0;
    repeat (6) @(posedge dac_clk);
    if (master_armed || follower_armed) begin
      $error("ABORT_MUTE must clear the ARM state");
      $finish;
    end

    $display("PASS: RFCTRL2 master epoch, external sync, START_AT, and abort are deterministic");
    $finish;
  end

  initial begin
    repeat (500) @(posedge dac_clk);
    $error("RFCTRL2 sync controller test timed out: master_tick=%0d follower_tick=%0d", master_tick, follower_tick);
    $finish;
  end
endmodule
