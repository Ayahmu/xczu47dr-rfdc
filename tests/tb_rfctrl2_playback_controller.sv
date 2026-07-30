`timescale 1ns / 1ps

module tb_rfctrl2_playback_controller;
  reg ddr_clk = 1'b0;
  reg dac_clk = 1'b0;
  reg ddr_rst_n = 1'b0;
  reg dac_rst_n = 1'b0;

  reg arm = 1'b0;
  reg trigger = 1'b0;
  reg abort = 1'b0;

  wire prepare_pulse;
  wire trigger_pulse;
  wire abort_pulse;
  wire armed;
  wire [63:0] hardware_tick;
  wire start_pending;

  rfctrl2_playback_controller dut (
    .ddr_clk(ddr_clk),
    .ddr_rst_n(ddr_rst_n),
    .rfctrl2_arm_pulse(arm),
    .rfctrl2_trigger_pulse(trigger),
    .rfctrl2_abort_mute_pulse(abort),
    .dac_clk(dac_clk),
    .dac_rst_n(dac_rst_n),
    .play_prepare_pulse(prepare_pulse),
    .play_trigger_pulse(trigger_pulse),
    .play_abort_pulse(abort_pulse),
    .armed(armed),
    .hardware_tick(hardware_tick),
    .start_pending(start_pending)
  );

  always #5 ddr_clk = ~ddr_clk;
  always #3 dac_clk = ~dac_clk;

  task ddr_pulse_arm;
    begin
      @(negedge ddr_clk); arm = 1'b1;
      @(negedge ddr_clk); arm = 1'b0;
    end
  endtask

  task ddr_pulse_trigger;
    begin
      @(negedge ddr_clk); trigger = 1'b1;
      @(negedge ddr_clk); trigger = 1'b0;
    end
  endtask

  task ddr_pulse_abort;
    begin
      @(negedge ddr_clk); abort = 1'b1;
      @(negedge ddr_clk); abort = 1'b0;
    end
  endtask

  initial begin
    repeat (4) @(posedge ddr_clk);
    ddr_rst_n = 1'b1;
    dac_rst_n = 1'b1;
    repeat (4) @(posedge dac_clk);

    ddr_pulse_trigger();
    repeat (12) @(posedge dac_clk);
    if (trigger_pulse) begin
      $error("TRIGGER before ARM must not open playback");
      $finish;
    end

    ddr_pulse_arm();
    wait (prepare_pulse);
    repeat (2) @(posedge dac_clk);
    if (!armed) begin
      $error("ARM did not enter armed session");
      $finish;
    end

    ddr_pulse_trigger();
    wait (trigger_pulse);
    repeat (2) @(posedge dac_clk);
    if (!armed) begin
      $error("TRIGGER must not clear armed session");
      $finish;
    end

    ddr_pulse_abort();
    wait (abort_pulse);
    repeat (2) @(posedge dac_clk);
    if (armed || start_pending) begin
      $error("ABORT/MUTE did not clear single-board playback session");
      $finish;
    end

    if (hardware_tick == 64'd0) begin
      $error("hardware_tick did not advance");
      $finish;
    end

    $display("PASS: RFCTRL2 single-board playback CDC arms, triggers, and aborts without board sync");
    $finish;
  end

  initial begin
    #5000;
    $error("RFCTRL2 single-board playback CDC test timed out");
    $finish;
  end
endmodule
