`timescale 1ns/1ps

// Covers the two new DAC-domain trigger blocks:
//   dac_ext_trigger_capture   - direct XS19 capture + one-per-PREPARED interlock
//   dac_trigger_latency_probe - in-situ measurement of the hmc_pl_clk detour
module tb_dac_direct_trigger;
  reg clk = 1'b0;
  reg rst_n = 1'b0;
  reg trigger_in = 1'b0;
  reg gate_open = 1'b0;
  reg clear = 1'b0;

  wire        cap_pulse;
  wire        cap_edge_raw;
  wire [31:0] cap_input_count;
  wire [31:0] cap_accept_count;
  wire        cap_sync;
  wire        cap_latched;

  reg         legacy_pulse = 1'b0;
  reg         started_pulse = 1'b0;
  wire [31:0] probe_tick;
  wire [15:0] delta_last, delta_min, delta_max, start_delta_last;
  wire [31:0] pair_count, orphan_count;
  wire        pair_pending;

  integer errors = 0;
  reg [31:0] orphan_base = 32'd0;

  always #10 clk = ~clk; // 50 MHz dac_axis_clk

  dac_ext_trigger_capture cap_i (
      .clk(clk), .rst_n(rst_n),
      .trigger_in(trigger_in), .gate_open(gate_open), .clear(clear),
      .trigger_pulse(cap_pulse), .trigger_edge_raw(cap_edge_raw),
      .input_count(cap_input_count), .accept_count(cap_accept_count),
      .trigger_in_sync(cap_sync), .trigger_latched(cap_latched)
  );

  dac_trigger_latency_probe #(.PAIR_TIMEOUT_CYCLES(16)) probe_i (
      .clk(clk), .rst_n(rst_n),
      .direct_pulse(cap_pulse), .legacy_pulse(legacy_pulse),
      .started_pulse(started_pulse),
      .tick(probe_tick),
      .delta_last(delta_last), .delta_min(delta_min), .delta_max(delta_max),
      .start_delta_last(start_delta_last),
      .pair_count(pair_count), .orphan_count(orphan_count),
      .pair_pending(pair_pending)
  );

  // Emit one external Trigger pulse, wide enough for the 3-stage synchronizer.
  task send_trigger;
    begin
      trigger_in = 1'b1;
      repeat (4) @(posedge clk);
      trigger_in = 1'b0;
      repeat (6) @(posedge clk);
    end
  endtask

  // The real external Trigger is ~8 ns, shorter than half this 20 ns clock.
  // Place it strictly between two posedges so a clocked sampler would see
  // nothing at all: only the asynchronous latch can catch it.
  task send_narrow_trigger(input real width_ns);
    begin
      @(posedge clk);
      #4;
      trigger_in = 1'b1;
      #(width_ns);
      trigger_in = 1'b0;
      repeat (12) @(posedge clk);
    end
  endtask

  task check(input cond, input [8*64-1:0] label);
    begin
      if (!cond) begin
        $display("FAIL: %0s", label);
        errors = errors + 1;
      end
    end
  endtask
  initial begin
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (3) @(posedge clk);

    // 1. Gate closed: the edge is counted but never accepted.
    gate_open = 1'b0;
    send_trigger();
    check(cap_input_count == 32'd1, "closed gate did not count the input edge");
    check(cap_accept_count == 32'd0, "closed gate accepted a Trigger");

    // 2. Gate open: exactly one accept.
    gate_open = 1'b1;
    send_trigger();
    check(cap_input_count == 32'd2, "open gate lost an input edge");
    check(cap_accept_count == 32'd1, "open gate did not accept exactly one Trigger");

    // 3. Interlock: a second Trigger inside the same PREPARED interval is
    //    ignored even though the gate is still open.
    send_trigger();
    check(cap_input_count == 32'd3, "interlock lost an input edge");
    check(cap_accept_count == 32'd1, "interlock let a second Trigger through");

    // 4. PREPARED drops and rises: the next Trigger is accepted again.
    gate_open = 1'b0;
    repeat (2) @(posedge clk);
    gate_open = 1'b1;
    repeat (2) @(posedge clk);
    send_trigger();
    check(cap_accept_count == 32'd2, "re-arm after PREPARED did not accept");

    // 5. ABORT/MUTE clears the consumed marker without a PREPARED gap.
    clear = 1'b1;
    @(posedge clk);
    clear = 1'b0;
    repeat (2) @(posedge clk);
    send_trigger();
    check(cap_accept_count == 32'd3, "clear did not re-arm the interlock");

    if (errors == 0)
      $display("PASS: dac_ext_trigger_capture gates, counts and interlocks correctly");
    else begin
      $display("FAIL: dac_ext_trigger_capture had %0d error(s)", errors);
      $finish;
    end

    run_narrow_pulse_checks();
    run_probe_checks();

    if (errors == 0)
      $display("PASS: DAC direct trigger capture and latency probe behave as specified");
    else
      $display("FAIL: %0d error(s) total", errors);
    $finish;
  end

  // Drive one direct/legacy pair, with the legacy pulse `gap` cycles after the
  // direct pulse is actually observed.  Keying off cap_pulse instead of
  // counting from trigger_in keeps this immune to the capture pipeline depth.
  task pair_with_gap(input integer gap);
    integer k;
    begin
      gate_open = 1'b0;
      repeat (2) @(posedge clk);
      gate_open = 1'b1;
      repeat (2) @(posedge clk);
      #4;
      trigger_in = 1'b1;
      #8;                      // narrow, like the real external Trigger
      trigger_in = 1'b0;
      @(posedge clk iff cap_pulse);
      for (k = 0; k < gap; k = k + 1) @(posedge clk);
      legacy_pulse = 1'b1;
      @(posedge clk);
      legacy_pulse = 1'b0;
      repeat (6) @(posedge clk);
    end
  endtask

  task run_narrow_pulse_checks;
    reg [31:0] base_in;
    reg [31:0] base_acc;
    begin
      // 10. An 8 ns pulse placed entirely between two clk posedges is still
      //     captured.  This is the real external Trigger width.
      gate_open = 1'b0;
      repeat (2) @(posedge clk);
      gate_open = 1'b1;
      repeat (2) @(posedge clk);
      base_in = cap_input_count;
      base_acc = cap_accept_count;
      send_narrow_trigger(8.0);
      check(cap_input_count == base_in + 32'd1,
            "8 ns pulse between clock edges was not latched");
      check(cap_accept_count == base_acc + 32'd1,
            "8 ns pulse was latched but not accepted");

      // 11. Even a 2 ns pulse survives; the latch only needs a set pulse.
      gate_open = 1'b0;
      repeat (2) @(posedge clk);
      gate_open = 1'b1;
      repeat (2) @(posedge clk);
      base_acc = cap_accept_count;
      send_narrow_trigger(2.0);
      check(cap_accept_count == base_acc + 32'd1, "2 ns pulse was lost");

      // 12. Two narrow pulses inside one PREPARED interval still yield one
      //     accept - the interlock is not defeated by the latch.
      gate_open = 1'b0;
      repeat (2) @(posedge clk);
      gate_open = 1'b1;
      repeat (2) @(posedge clk);
      base_acc = cap_accept_count;
      send_narrow_trigger(8.0);
      send_narrow_trigger(8.0);
      check(cap_accept_count == base_acc + 32'd1,
            "two narrow pulses in one PREPARED interval produced two accepts");

      // 13. The latch does not stay stuck: after the traffic above it must be
      //     released, otherwise no further Trigger could ever be seen.
      repeat (8) @(posedge clk);
      check(!cap_latched, "capture latch stayed set and would block new Triggers");

      if (errors == 0)
        $display("PASS: 8 ns external Trigger pulses are captured without a clock edge");
      else begin
        $display("FAIL: narrow-pulse capture had %0d error(s)", errors);
        $finish;
      end
    end
  endtask

  task run_probe_checks;
    reg [31:0] pair_base;
    reg [15:0] delta_small;
    begin
      // The probe measures a fixed pipeline offset plus the requested gap, so
      // these assert relationships rather than absolute cycle counts.
      pair_base = pair_count;

      // 14. One pair recorded; min == max == last after the first one.
      pair_with_gap(2);
      check(pair_count == pair_base + 32'd1, "probe did not record the first pair");
      check(delta_min == delta_last && delta_max == delta_last,
            "probe min/max disagree with last after a single pair");
      delta_small = delta_last;

      // 15. A gap 3 cycles wider moves delta_last and delta_max by exactly 3
      //     and leaves delta_min alone.
      pair_with_gap(5);
      check(pair_count == pair_base + 32'd2, "probe did not record the second pair");
      check(delta_last == delta_small + 16'd3,
            "probe did not track a 3-cycle wider gap");
      check(delta_min == delta_small, "probe delta_min drifted");
      check(delta_max == delta_small + 16'd3,
            "probe delta_max did not follow the wider gap");

      // 16. A missing legacy pulse times out into an orphan, and the next pair
      //     still measures correctly.
      orphan_base = orphan_count;
      gate_open = 1'b0;
      repeat (2) @(posedge clk);
      gate_open = 1'b1;
      repeat (2) @(posedge clk);
      send_trigger();
      repeat (24) @(posedge clk);
      check(orphan_count == orphan_base + 32'd1,
            "probe did not flag a missing legacy pulse");
      check(!pair_pending, "probe stayed pending after the timeout");
      pair_with_gap(2);
      check(pair_count == pair_base + 32'd3 && delta_last == delta_small,
            "probe did not recover after an orphan");

      // 17. started_pulse records capture-to-playback latency.
      gate_open = 1'b0;
      repeat (2) @(posedge clk);
      gate_open = 1'b1;
      repeat (2) @(posedge clk);
      send_trigger();
      repeat (5) @(posedge clk);
      started_pulse = 1'b1;
      @(posedge clk);
      started_pulse = 1'b0;
      @(posedge clk);
      check(start_delta_last >= 16'd1 && start_delta_last <= 16'd20,
            "probe recorded an implausible start delta");
    end
  endtask

  initial begin
    #200000;
    $display("FAIL: DAC direct trigger test timed out");
    $finish;
  end
endmodule
