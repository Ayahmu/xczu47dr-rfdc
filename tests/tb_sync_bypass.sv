`timescale 1ns/1ps

module tb_sync_bypass;
  reg ddr_clk = 1'b0;
  reg pl_clk = 1'b0;
  reg ddr_rst_n = 1'b0;
  reg pl_rst_n = 1'b0;
  reg trigger_in = 1'b0;
  reg sync_bypass = 1'b0;
  wire role_trigger;
  wire sync_ready;
  wire sync_seen;
  integer accepted = 0;

  always #5 ddr_clk = ~ddr_clk;
  always #7 pl_clk = ~pl_clk;

  sync_trigger_link #(.IS_MASTER(0), .WAIT_CYCLES(3), .HIGH_CYCLES(2)) dut (
      .ddr_clk(ddr_clk), .ddr_rst_n(ddr_rst_n),
      .pl_clk(pl_clk), .pl_rst_n(pl_rst_n),
      .sync_request_ddr(1'b0), .trigger_request_ddr(1'b0),
      .sync_request_vio_pl(1'b0), .sync_in(1'b0),
      .trigger_in(trigger_in), .dac_trigger_start(1'b0),
      .role_master(1'b0), .sync_bypass(sync_bypass),
      .hmc_sync(), .sync_link_out(), .trigger_link_out(),
      .role_trigger_raw(role_trigger), .sync_done(),
      .sync_seen(sync_seen), .sync_link_ready(sync_ready),
      .trigger_in_seen(), .trigger_accepted(), .trigger_output_active(),
      .trigger_input_count(), .trigger_accepted_count(), .trigger_output_count()
  );

  always @(posedge pl_clk)
    if (role_trigger) accepted <= accepted + 1;

  initial begin
    repeat (3) @(negedge pl_clk);
    ddr_rst_n = 1'b1;
    pl_rst_n = 1'b1;
    repeat (3) @(posedge pl_clk);
    sync_bypass = 1'b1;
    repeat (3) @(posedge pl_clk);
    if (sync_seen || !sync_ready) begin
      $display("FAIL: bypass did not open the trigger gate without fabricating XS20 SYNC");
      $finish;
    end
    @(negedge pl_clk); trigger_in = 1'b1;
    @(negedge pl_clk); trigger_in = 1'b0;
    repeat (5) @(posedge pl_clk);
    if (accepted != 1) begin
      $display("FAIL: bypass accepted trigger count=%0d expected 1", accepted);
      $finish;
    end
    $display("PASS: bypass accepts XS19 trigger without XS20 SYNC");
    $finish;
  end
endmodule
