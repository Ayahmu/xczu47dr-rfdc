`timescale 1ns/1ps

module tb_sync_trigger_link;
  reg ddr_clk = 1'b0;
  reg pl_clk = 1'b0;
  reg ddr_rst_n = 1'b0;
  reg pl_rst_n = 1'b0;
  reg sync_request_ddr = 1'b0;
  reg trigger_request_ddr = 1'b0;
  wire master_sync_link;
  wire master_trigger_link;
  wire slave_hmc_sync;
  wire master_hmc_sync;
  wire master_done;
  wire slave_done;
  wire master_seen;
  wire slave_seen;
  wire slave_ready;
  wire slave_trigger;

  always #5 ddr_clk = ~ddr_clk;
  always #7 pl_clk = ~pl_clk;

  sync_trigger_link #(
      .IS_MASTER(1),
      .WAIT_CYCLES(3),
      .HIGH_CYCLES(2)
  ) master_i (
      .ddr_clk(ddr_clk), .ddr_rst_n(ddr_rst_n),
      .pl_clk(pl_clk), .pl_rst_n(pl_rst_n),
      .sync_request_ddr(sync_request_ddr),
      .trigger_request_ddr(trigger_request_ddr),
      .sync_request_vio_pl(1'b0), .sync_in(1'b0),
      .trigger_in(1'b0), .role_master(1'b1), .sync_bypass(1'b0),
      .dac_trigger_start(1'b0),
      .hmc_sync(master_hmc_sync), .sync_link_out(master_sync_link),
      .trigger_link_out(master_trigger_link),
      .role_trigger_raw(), .sync_done(master_done),
      .sync_seen(master_seen), .sync_link_ready(), .trigger_in_seen(),
      .trigger_accepted(), .trigger_output_active(),
      .trigger_input_count(), .trigger_accepted_count(), .trigger_output_count()
  );

  sync_trigger_link #(
      .IS_MASTER(0),
      .WAIT_CYCLES(3),
      .HIGH_CYCLES(2)
  ) slave_i (
      .ddr_clk(ddr_clk), .ddr_rst_n(ddr_rst_n),
      .pl_clk(pl_clk), .pl_rst_n(pl_rst_n),
      .sync_request_ddr(1'b0), .trigger_request_ddr(1'b0),
      .sync_request_vio_pl(1'b0), .sync_in(master_sync_link),
      .trigger_in(master_trigger_link), .role_master(1'b0), .sync_bypass(1'b0),
      .dac_trigger_start(1'b0),
      .hmc_sync(slave_hmc_sync), .sync_link_out(), .trigger_link_out(),
      .role_trigger_raw(slave_trigger), .sync_done(slave_done),
      .sync_seen(slave_seen), .sync_link_ready(slave_ready), .trigger_in_seen(),
      .trigger_accepted(), .trigger_output_active(),
      .trigger_input_count(), .trigger_accepted_count(), .trigger_output_count()
  );

  integer master_hmc_rises = 0;
  integer slave_hmc_rises = 0;
  integer slave_trigger_rises = 0;
  integer master_done_count = 0;
  integer slave_done_count = 0;
  reg master_hmc_d = 1'b0;
  reg slave_hmc_d = 1'b0;
  reg slave_trigger_d = 1'b0;
  reg trigger_seen_during_sync = 1'b0;

  always @(posedge pl_clk) begin
    master_hmc_d <= master_hmc_sync;
    slave_hmc_d <= slave_hmc_sync;
    slave_trigger_d <= slave_trigger;
    if (master_hmc_sync && !master_hmc_d)
      master_hmc_rises <= master_hmc_rises + 1;
    if (slave_hmc_sync && !slave_hmc_d)
      slave_hmc_rises <= slave_hmc_rises + 1;
    if (slave_trigger && !slave_trigger_d)
      slave_trigger_rises <= slave_trigger_rises + 1;
    if (master_done)
      master_done_count <= master_done_count + 1;
    if (slave_done)
      slave_done_count <= slave_done_count + 1;
    if (!slave_ready && slave_trigger)
      trigger_seen_during_sync <= 1'b1;
  end

  initial begin
    repeat (3) @(negedge pl_clk);
    ddr_rst_n = 1'b1;
    pl_rst_n = 1'b1;

    // One short DDR-domain pulse is deliberately placed between PL edges.
    @(negedge ddr_clk);
    sync_request_ddr = 1'b1;
    @(negedge ddr_clk);
    sync_request_ddr = 1'b0;
    repeat (45) @(posedge pl_clk);

    if (master_hmc_rises != 1 || slave_hmc_rises != 1) begin
      $display("FAIL: HMC rises master=%0d slave=%0d expected 1/1",
               master_hmc_rises, slave_hmc_rises);
      $finish;
    end
    if (master_done_count != 1 || slave_done_count != 1 ||
        !master_seen || !slave_seen) begin
      $display("FAIL: sync completion done=%0d/%0d seen=%b/%b",
               master_done_count, slave_done_count, master_seen, slave_seen);
      $finish;
    end
    if (!slave_ready || trigger_seen_during_sync) begin
      $display("FAIL: slave trigger gate ready=%b early=%b",
               slave_ready, trigger_seen_during_sync);
      $finish;
    end

    // A later master trigger must cross the same physical link but must not
    // create another HMC pulse on either board.
    @(negedge ddr_clk);
    trigger_request_ddr = 1'b1;
    @(negedge ddr_clk);
    trigger_request_ddr = 1'b0;
    repeat (12) @(posedge pl_clk);

    if (master_hmc_rises != 1 || slave_hmc_rises != 1) begin
      $display("FAIL: playback trigger changed HMC rises master=%0d slave=%0d",
               master_hmc_rises, slave_hmc_rises);
      $finish;
    end
    if (slave_trigger_rises != 1) begin
      $display("FAIL: slave playback trigger rises=%0d expected 1",
               slave_trigger_rises);
      $finish;
    end
    $display("PASS: single-pulse XS20 SYNC and independent XS18->XS19 trigger link");
    $finish;
  end
endmodule
