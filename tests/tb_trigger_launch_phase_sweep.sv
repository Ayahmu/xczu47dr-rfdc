`timescale 1ns/1fs

// Quantifies, in simulation, what the hmc_pl_clk detour costs versus capturing
// XS19 directly in dac_axis_clk.
//
// Both clocks descend from the same HMC7044 VCO: 96 MHz and 50 MHz, period
// ratio 25:48, so they are frequency-locked with a static phase and the pattern
// repeats every 500 ns.  gcd(20, 125/12) = 5/12 ns, so a hmc_pl_clk edge can
// land at one of 48 positions inside the 20 ns DAC period.  The claim under
// test is that this alone spreads the launch by ~19.6 ns even when XS19 is
// perfectly clean, and that the direct capture removes that term.
//
// The sweep does not manipulate sub-nanosecond trigger placement; it simply
// sends many Triggers at a spacing that is not a multiple of 500 ns, so the
// capture phase walks through the lattice the way it does on hardware.
module tb_trigger_launch_phase_sweep;
  localparam real HMC_PERIOD = 10.4166667;  // 96 MHz  PL_CLK from HMC7044
  localparam real DAC_PERIOD = 20.0;        // 50 MHz  RFDC DAC AXIS
  localparam integer TRIGGER_COUNT = 128;
  // One full 500 ns hmc/dac phase repeat, sampled at 128 points.  500/128 is
  // not a multiple of the 5/12 ns lattice, so the sweep does not alias onto a
  // subset of the phases.
  localparam real PHASE_STEP = 500.0 / 128.0;

  reg hmc_clk = 1'b0;
  reg dac_clk = 1'b0;
  reg hmc_rst_n = 1'b0;
  reg dac_rst_n = 1'b0;
  reg ddr_clk = 1'b0;
  reg pl_clk = 1'b0;

  always #(HMC_PERIOD / 2.0) hmc_clk = ~hmc_clk;
  always #(DAC_PERIOD / 2.0) dac_clk = ~dac_clk;
  always #2.5 ddr_clk = ~ddr_clk;
  always #5.0 pl_clk = ~pl_clk;

  reg trig_in = 1'b0;
  reg prepared = 1'b0;

  // ---- legacy path: XS19 -> hmc_pl_clk -> toggle CDC -> dac_axis_clk ----
  wire trigger_event_toggle_hmc;
  wire trigger_event_external_hmc;
  wire [63:0] cap_tick, launch_tick, hmc_tick, sync_tick;

  sync_trigger_link #(
      .IS_MASTER(0), .WAIT_CYCLES(20), .HIGH_CYCLES(4)
  ) legacy_i (
      .ddr_clk(ddr_clk), .ddr_rst_n(hmc_rst_n),
      .pl_clk(pl_clk), .pl_rst_n(hmc_rst_n),
      .hmc_pl_clk(hmc_clk), .hmc_pl_rst_n(hmc_rst_n),
      .sync_request_ddr(1'b0), .trigger_request_ddr(1'b0),
      .emit_trigger_request_ddr(1'b0), .sync_request_vio_pl(1'b0),
      .sync_in(1'b0), .trigger_in(trig_in), .dac_trigger_start(1'b0),
      .role_master(1'b0), .sync_bypass(1'b1), .playback_prepared(prepared),
      .firmware_ack_epoch(6'd0), .firmware_align_failed(1'b0),
      .hmc_sync(), .sync_link_out(), .trigger_link_out(),
      .role_trigger_raw(), .trigger_event_toggle(trigger_event_toggle_hmc),
      .trigger_event_external(trigger_event_external_hmc),
      .sync_done(), .sync_seen(), .sync_link_ready(), .sync_event_epoch(),
      .sync_align_busy(), .sync_align_failed(), .sync_alignment_epoch(),
      .trigger_in_seen(), .trigger_accepted(), .trigger_output_active(),
      .trigger_input_count(), .trigger_accepted_count(), .trigger_output_count(),
      .hmc_event_tick(hmc_tick), .sync_event_tick(sync_tick),
      .trigger_capture_tick(cap_tick), .trigger_launch_tick(launch_tick)
  );

  // Same three-stage toggle CDC that Top.v uses.
  (* ASYNC_REG = "TRUE" *) reg [2:0] legacy_dac_sync;
  reg legacy_dac_seen;
  always @(posedge dac_clk or negedge dac_rst_n) begin
    if (!dac_rst_n) begin
      legacy_dac_sync <= 3'b000;
      legacy_dac_seen <= 1'b0;
    end else begin
      legacy_dac_sync <= {legacy_dac_sync[1:0], trigger_event_toggle_hmc};
      legacy_dac_seen <= legacy_dac_sync[2];
    end
  end
  wire legacy_pulse = legacy_dac_sync[2] != legacy_dac_seen;

  // ---- new path: XS19 captured directly in dac_axis_clk ----
  wire direct_pulse;
  dac_ext_trigger_capture direct_i (
      .clk(dac_clk), .rst_n(dac_rst_n),
      .trigger_in(trig_in), .gate_open(prepared), .clear(1'b0),
      .trigger_pulse(direct_pulse), .trigger_edge_raw(),
      .input_count(), .accept_count(), .trigger_in_sync(),
      .trigger_latched()
  );
  // ---- measurement ----
  real t_trigger;
  real lat_legacy [0:TRIGGER_COUNT-1];
  real lat_direct [0:TRIGGER_COUNT-1];
  integer idx = 0;
  integer legacy_seen_i = 0;
  integer direct_seen_i = 0;
  real legacy_min, legacy_max, direct_min, direct_max;
  integer distinct_deltas = 0;
  integer wide_deltas = 0;
  integer captured_direct = 0;
  integer captured_legacy = 0;
  integer delta_hist [0:63];
  integer i, d;

  always @(posedge dac_clk) begin
    if (direct_pulse && direct_seen_i == idx && idx < TRIGGER_COUNT) begin
      lat_direct[idx] = $realtime - t_trigger;
      direct_seen_i = idx + 1;
    end
    if (legacy_pulse && legacy_seen_i == idx && idx < TRIGGER_COUNT) begin
      lat_legacy[idx] = $realtime - t_trigger;
      legacy_seen_i = idx + 1;
    end
  end

  // Re-arm, then drive one XS19 pulse of the given width.  The inter-trigger
  // gap is deliberately not a multiple of 500 ns so the hmc_pl_clk capture
  // phase walks the lattice.
  task send_one(input real extra_gap, input real width);
    begin
      prepared = 1'b0;
      #60;
      prepared = 1'b1;
      #(40.0 + extra_gap);
      t_trigger = $realtime;
      trig_in = 1'b1;
      #(width);
      trig_in = 1'b0;
      #400;
    end
  endtask

  task run_sweep(input real width, input [8*16-1:0] label);
    integer n_direct, n_legacy;
    begin
      legacy_seen_i = 0;
      direct_seen_i = 0;
      distinct_deltas = 0;
      for (i = 0; i < 64; i = i + 1) delta_hist[i] = 0;

      for (idx = 0; idx < TRIGGER_COUNT; idx = idx + 1) begin
        lat_legacy[idx] = -1.0;
        lat_direct[idx] = -1.0;
        send_one(idx * PHASE_STEP, width);
        // Neither path may carry a stale pending event into the next step.
        legacy_seen_i = idx + 1;
        direct_seen_i = idx + 1;
      end
      idx = TRIGGER_COUNT;

      n_direct = 0; n_legacy = 0;
      legacy_min = 1e9; legacy_max = -1e9;
      direct_min = 1e9; direct_max = -1e9;
      for (i = 0; i < TRIGGER_COUNT; i = i + 1) begin
        if (lat_direct[i] >= 0.0) begin
          n_direct = n_direct + 1;
          if (lat_direct[i] < direct_min) direct_min = lat_direct[i];
          if (lat_direct[i] > direct_max) direct_max = lat_direct[i];
        end
        if (lat_legacy[i] >= 0.0) begin
          n_legacy = n_legacy + 1;
          if (lat_legacy[i] < legacy_min) legacy_min = lat_legacy[i];
          if (lat_legacy[i] > legacy_max) legacy_max = lat_legacy[i];
        end
        if (lat_direct[i] >= 0.0 && lat_legacy[i] >= 0.0) begin
          d = $rtoi((lat_legacy[i] - lat_direct[i]) / DAC_PERIOD + 0.5);
          if (d >= 0 && d < 64) begin
            if (delta_hist[d] == 0) distinct_deltas = distinct_deltas + 1;
            delta_hist[d] = delta_hist[d] + 1;
          end
        end
      end

      $display("");
      $display("=== %0s XS19 pulse, %0d triggers ===", label, TRIGGER_COUNT);
      $display("  direct (dac_axis_clk) captured : %0d / %0d", n_direct, TRIGGER_COUNT);
      $display("  legacy (hmc_pl_clk)  captured : %0d / %0d", n_legacy, TRIGGER_COUNT);
      if (n_direct > 0)
        $display("  direct span : %0.3f ns  (min %0.3f max %0.3f)",
                 direct_max - direct_min, direct_min, direct_max);
      if (n_legacy > 0)
        $display("  legacy span : %0.3f ns  (min %0.3f max %0.3f)",
                 legacy_max - legacy_min, legacy_min, legacy_max);
      $display("  legacy-direct delta : %0d distinct value(s) in DAC cycles",
               distinct_deltas);
      for (i = 0; i < 64; i = i + 1)
        if (delta_hist[i] > 0)
          $display("     %0d cycles (%0.1f ns) : %0d trigger(s)",
                   i, i * DAC_PERIOD, delta_hist[i]);
      captured_direct = n_direct;
      captured_legacy = n_legacy;
    end
  endtask

  initial begin
    #40;
    hmc_rst_n = 1'b1;
    dac_rst_n = 1'b1;
    #100;

    // 1) The 83 ns XS18 loopback that the bench currently uses.  Both paths see
    //    every Trigger, so this isolates the clock-domain quantization.
    run_sweep(83.0, "83 ns (XS18)");
    if (captured_direct != TRIGGER_COUNT || captured_legacy != TRIGGER_COUNT) begin
      $display("FAIL: a wide pulse should never be missed (direct=%0d legacy=%0d)",
               captured_direct, captured_legacy);
      $finish;
    end
    if (distinct_deltas < 2) begin
      $display("FAIL: the hmc_pl_clk detour added a constant delay; the 48-phase");
      $display("      model does not reproduce and cannot be the dominant term");
      $finish;
    end
    if (legacy_max - legacy_min <= direct_max - direct_min) begin
      $display("FAIL: legacy span %0.3f ns is not worse than direct span %0.3f ns",
               legacy_max - legacy_min, direct_max - direct_min);
      $finish;
    end
    wide_deltas = distinct_deltas;

    // 2) The real external Trigger: ~8 ns, shorter than one hmc_pl_clk period.
    //    The direct path latches asynchronously and must still catch all of
    //    them; the hmc_pl_clk sampler necessarily drops a share.
    run_sweep(8.0, "8 ns (external)");
    if (captured_direct != TRIGGER_COUNT) begin
      $display("FAIL: direct capture lost %0d of %0d narrow Triggers",
               TRIGGER_COUNT - captured_direct, TRIGGER_COUNT);
      $finish;
    end
    if (captured_legacy >= TRIGGER_COUNT) begin
      $display("FAIL: hmc_pl_clk sampling should not survive an 8 ns pulse intact;");
      $display("      the test is not exercising what it claims");
      $finish;
    end

    $display("");
    $display("PASS: hmc_pl_clk detour spreads launch over %0d DAC cycles and drops",
             wide_deltas);
    $display("      %0d/%0d of 8 ns Triggers; direct async capture keeps all of them",
             TRIGGER_COUNT - captured_legacy, TRIGGER_COUNT);
    $finish;
  end

  initial begin
    #4000000;
    $display("FAIL: phase sweep timed out");
    $finish;
  end
endmodule
