`timescale 1ns/1ps

module tb_sync_bypass;
  reg ddr_clk = 1'b0;
  reg pl_clk = 1'b0;
  reg hmc_pl_clk = 1'b0;
  reg ddr_rst_n = 1'b0;
  reg pl_rst_n = 1'b0;
  reg hmc_pl_rst_n = 1'b0;
  reg trigger_in = 1'b0;
  reg trigger_request_ddr = 1'b0;
  reg sync_bypass = 1'b0;
  reg playback_prepared = 1'b1;
  wire role_trigger;
  wire sync_ready;
  wire sync_seen;
  wire trigger_accepted;
  wire [31:0] trigger_accepted_count;
  wire [31:0] trigger_output_count;
  integer accepted = 0;

  always #5 ddr_clk = ~ddr_clk;
  always #7 pl_clk = ~pl_clk;
  always #5.208333 hmc_pl_clk = ~hmc_pl_clk;

  sync_trigger_link #(.IS_MASTER(0), .WAIT_CYCLES(3), .HIGH_CYCLES(2)) dut (
      .ddr_clk(ddr_clk), .ddr_rst_n(ddr_rst_n),
      .pl_clk(pl_clk), .pl_rst_n(pl_rst_n),
      .hmc_pl_clk(hmc_pl_clk), .hmc_pl_rst_n(hmc_pl_rst_n),
      .sync_request_ddr(1'b0), .trigger_request_ddr(trigger_request_ddr),
      .emit_trigger_request_ddr(1'b0),
      .sync_request_vio_pl(1'b0), .sync_in(1'b0),
      .trigger_in(trigger_in), .dac_trigger_start(1'b0),
      .role_master(1'b0), .sync_bypass(sync_bypass),
      .playback_prepared(playback_prepared),
      .hmc_sync(), .sync_link_out(), .trigger_link_out(),
      .role_trigger_raw(role_trigger), .trigger_event_toggle(), .sync_done(),
      .sync_seen(sync_seen), .sync_link_ready(sync_ready),
      .trigger_in_seen(), .trigger_accepted(trigger_accepted), .trigger_output_active(),
      .trigger_input_count(), .trigger_accepted_count(trigger_accepted_count), .trigger_output_count(trigger_output_count),
      .hmc_event_tick(), .sync_event_tick(), .trigger_capture_tick(), .trigger_launch_tick()
  );

  always @(posedge hmc_pl_clk)
    if (role_trigger) accepted <= accepted + 1;

  initial begin
    repeat (3) @(negedge pl_clk);
    ddr_rst_n = 1'b1;
    pl_rst_n = 1'b1;
    hmc_pl_rst_n = 1'b1;
    repeat (3) @(posedge pl_clk);
    sync_bypass = 1'b1;
    repeat (3) @(posedge pl_clk);
    if (sync_seen || !sync_ready) begin
      $display("FAIL: bypass did not open the trigger gate without fabricating XS20 SYNC");
      $finish;
    end
    @(negedge pl_clk); trigger_in = 1'b1;
    @(negedge pl_clk); trigger_in = 1'b0;
    repeat (12) @(posedge hmc_pl_clk);
    if (accepted != 1) begin
      $display("FAIL: bypass accepted trigger count=%0d expected 1", accepted);
      $finish;
    end

    // One finite frame has been consumed.  The executor must drop PREPARED
    // while refilling, then raise it again before the next Trigger can fire.
    playback_prepared = 1'b0;
    repeat (6) @(posedge hmc_pl_clk);
    playback_prepared = 1'b1;
    repeat (6) @(posedge hmc_pl_clk);

    // A slave in bypass mode also accepts an RFCTRL2 software Trigger for
    // local playback.  It must not drive XS18, which is master-only.
    @(negedge ddr_clk); trigger_request_ddr = 1'b1;
    @(negedge ddr_clk); trigger_request_ddr = 1'b0;
    repeat (16) @(posedge hmc_pl_clk);
    if (accepted != 2 || trigger_accepted_count != 32'd2) begin
      $display("FAIL: bypass did not accept local RFCTRL2 Trigger count=%0d accepted_count=%0d", accepted, trigger_accepted_count);
      $finish;
    end
    if (trigger_output_count != 32'd0) begin
      $display("FAIL: slave bypass local Trigger incorrectly drove XS18 count=%0d", trigger_output_count);
      $finish;
    end

    // Returning to external mode closes the local software path again.  A
    // host Trigger must not launch until a real XS20 SYNC is received.
    sync_bypass = 1'b0;
    repeat (6) @(posedge pl_clk);
    @(negedge ddr_clk); trigger_request_ddr = 1'b1;
    @(negedge ddr_clk); trigger_request_ddr = 1'b0;
    repeat (16) @(posedge hmc_pl_clk);
    if (trigger_accepted_count != 32'd2) begin
      $display("FAIL: external-mode slave accepted local Trigger count=%0d", trigger_accepted_count);
      $finish;
    end
    $display("PASS: bypass accepts XS19 and local RFCTRL2 Trigger without XS20 SYNC");
    $finish;
  end
endmodule
