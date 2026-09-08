`timescale 1ns/1ps
module tb_tdc_compensating_trigger;
  reg clk = 0;
  always #10 clk = !clk;
  reg rst_n = 0, clear = 0, enable = 1, calibrated = 1, reference_ready = 1;
  reg prepared = 0, source_running = 0, output_busy = 0, source_done = 0;
  reg loop_enable = 0, runtime_fault = 0, event_valid = 0, event_good = 1;
  reg [31:0] epoch = 0, event_epoch = 0;
  reg [10:0] phase = 0;
  reg signed [15:0] offset = 0;
  wire launch, config_valid, pending, active, fault;
  wire [2:0] shift;
  wire [5:0] fraction;
  wire [31:0] accepted, completed, rejected, late_count, faults, accepted_epoch;
  wire [10:0] accepted_phase;
  wire [7:0] clipped;
  integer p, delay_cycles, timeout;
  integer captured_epoch;
  real latency, smallest = 1e9, largest = -1e9;
  always @(posedge clk) if (!rst_n) epoch <= 0; else epoch <= epoch + 1;
  tdc_compensating_trigger dut (
      .clk(clk), .rst_n(rst_n), .clear(clear), .enable(enable), .calibrated(calibrated),
      .reference_ready(reference_ready), .prepared(prepared), .source_running(source_running),
      .output_busy(output_busy), .source_done(source_done), .loop_enable(loop_enable),
      .runtime_fault(runtime_fault), .clip_pulse(8'd0), .current_epoch(epoch),
      .event_valid(event_valid), .event_good(event_good), .event_epoch(event_epoch),
      .event_phase_10ps(phase), .phase_offset_10ps(offset), .clear_statistics(1'b0),
      .launch(launch), .config_valid(config_valid), .delay_samples(shift),
      .fractional_phase(fraction), .pending(pending), .active(active), .fault(fault),
      .accepted_count(accepted), .completed_count(completed), .rejected_count(rejected),
      .late_count(late_count), .fault_bits(faults), .clipped_channels(clipped),
      .accepted_epoch(accepted_epoch), .accepted_phase_10ps(accepted_phase)
  );
  task finish_event;
    begin
      @(negedge clk); prepared = 0; source_running = 1; output_busy = 1;
      repeat(3) @(negedge clk);
      source_running = 0; source_done = 1;
      @(negedge clk); source_done = 0;
      repeat(4) @(negedge clk);
      if (!active) $fatal(1, "Event ended before filter tail drained");
      output_busy = 0;
      repeat(2) @(negedge clk);
      if (active || pending || fault) $fatal(1, "Event did not finish after drain");
    end
  endtask
  initial begin
    repeat(3) @(negedge clk); rst_n = 1;
    // Sweep the full 20ns beat; independently vary descriptor transit latency.
    for (p = 0; p < 2000; p = p + 13) begin
      @(negedge clk); prepared = 1;
      repeat(2) @(negedge clk);
      captured_epoch = epoch;
      delay_cycles = 2 + (p % 13);
      repeat(delay_cycles) @(negedge clk);
      event_epoch = captured_epoch; phase = p; event_valid = 1;
      @(negedge clk); event_valid = 0;
      timeout = 0;
      while (!launch && timeout < 40) begin @(negedge clk); timeout = timeout + 1; end
      if (!launch) $fatal(1, "Missing scheduled launch for phase %0d", p);
      latency = 20.0 * (epoch - captured_epoch) + 2.5 * shift + 2.5 * fraction / 64.0 - p * 0.01;
      if (latency < smallest) smallest = latency;
      if (latency > largest) largest = latency;
      finish_event();
    end
    if (largest - smallest > 0.040) $fatal(1, "Compensation spread exceeds quantization step");
    if (accepted != completed) $fatal(1, "Accepted/completed mismatch");
    // Invalid measurement is rejected without arming the output.
    prepared = 1; repeat(2) @(negedge clk);
    event_epoch = epoch; phase = 17; event_good = 0; event_valid = 1;
    @(negedge clk); event_valid = 0; event_good = 1;
    if (active) $fatal(1, "Invalid measurement accepted");
    // A source fault must cancel an already scheduled output and latch failure.
    repeat(2) @(negedge clk);
    event_epoch = epoch; event_valid = 1;
    @(negedge clk); event_valid = 0;
    runtime_fault = 1;
    @(negedge clk); runtime_fault = 0;
    if (!fault || active || launch) $fatal(1, "Runtime fault did not cancel pending event");
    clear = 1; @(negedge clk); clear = 0;
    if (fault || active) $fatal(1, "Abort did not clear event state");
    // A descriptor for a trigger preceding the new PREPARED edge is stale.
    prepared = 0; repeat(3) @(negedge clk);
    prepared = 1; event_epoch = epoch-1; event_valid = 1;
    @(negedge clk); event_valid = 0;
    if(active) $fatal(1,"A pre-PREPARED descriptor was accepted on the admission edge");
    // Fast-forward a long idle interval without simulating 2^31 clock cycles.
    repeat(40) @(negedge clk);
    epoch = epoch + 32'h80000010;
    event_epoch = epoch-2; phase=321; event_valid=1;
    @(negedge clk); event_valid=0;
    if(!active) $fatal(1,"Long PREPARED wait rejected a fresh trigger");
    timeout=0;
    while(!launch && timeout<40) begin @(negedge clk); timeout=timeout+1; end
    if(!launch) $fatal(1,"Long-wait trigger missed its deadline");
    finish_event();
    prepared=1; repeat(40) @(negedge clk);
    epoch=32'hfffffff0; event_epoch=epoch; phase=1999; event_valid=1;
    @(negedge clk); event_valid=0;
    timeout=0;
    while(!launch && timeout<40) begin @(negedge clk); timeout=timeout+1; end
    if(!launch) $fatal(1,"Epoch wrap lost a scheduled event");
    finish_event();
    $display("PASS: full-phase timestamp scheduler, variable CDC latency, drain, rejection and abort; spread=%0.6f ns", largest-smallest);
    $finish;
  end
  initial begin #1000000; $fatal(1, "TIMEOUT"); end
endmodule
