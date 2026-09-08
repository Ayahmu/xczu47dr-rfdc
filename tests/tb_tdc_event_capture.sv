`timescale 1ns/1ps

module tb_tdc_event_capture;
  localparam integer TAPS = 2048;
  reg sample_clk = 1'b1;
  reg dac_clk = 1'b1;
  reg rst_n = 1'b0;
  reg trigger_in = 1'b0;
  reg ref_toggle = 1'b0;
  reg [31:0] dac_epoch = 32'd0;
  reg [31:0] ref_epoch = 32'd0;
  reg calib_wr_en = 1'b0;
  reg [10:0] calib_wr_addr = 11'd0;
  reg [15:0] calib_wr_data = 16'd0;
  reg [10:0] calib_rd_addr = 11'd0;
  wire [15:0] calib_rd_data;
  wire ready, event_valid, event_good, event_overflow, event_bubble;
  wire [31:0] event_epoch;
  wire [10:0] event_phase_10ps;
  wire [10:0] event_tap;
  integer event_count = 0;
  integer good_count = 0;
  integer overflow_count = 0;
  integer bubble_count = 0;
  integer last_timestamp;
  integer expected_timestamp;
  integer previous_count;
  integer phase;
  reg [TAPS-1:0] fault_sample;

  always #2.5 sample_clk = ~sample_clk;
  always #10 dac_clk = ~dac_clk;
  always @(posedge dac_clk or negedge rst_n) begin
    if (!rst_n) dac_epoch <= 32'd0;
    else dac_epoch <= dac_epoch + 32'd1;
  end
  always @(negedge dac_clk or negedge rst_n) begin
    if (!rst_n) begin
      ref_epoch <= 32'd0;
      ref_toggle <= 1'b0;
    end else begin
      ref_epoch <= dac_epoch;
      ref_toggle <= ~ref_toggle;
    end
  end

  tdc_event_capture #(.TAPS(TAPS), .DEFAULT_TAP_PS(10)) dut (
      .sample_clk(sample_clk), .rst_n(rst_n), .trigger_in(trigger_in),
      .ref_toggle(ref_toggle), .ref_epoch(ref_epoch),
      .calib_wr_en(calib_wr_en), .calib_wr_addr(calib_wr_addr),
      .calib_wr_data(calib_wr_data), .calib_rd_addr(calib_rd_addr),
      .calib_rd_data(calib_rd_data), .ready(ready),
      .event_valid(event_valid), .event_good(event_good),
      .event_overflow(event_overflow), .event_bubble(event_bubble),
      .event_epoch(event_epoch), .event_phase_10ps(event_phase_10ps), .event_tap(event_tap)
  );

  always @(posedge sample_clk) begin
    #0.001;
    if (event_valid) begin
      event_count = event_count + 1;
      if (event_good) good_count = good_count + 1;
      if (event_overflow) overflow_count = overflow_count + 1;
      if (event_bubble) bubble_count = bubble_count + 1;
      last_timestamp = event_epoch * 2000 + event_phase_10ps;
      if (event_phase_10ps >= 2000)
        $fatal(1, "Timestamp phase is not normalized");
      if ((event_good + event_overflow + event_bubble) != 1)
        $fatal(1, "Event classification must be mutually exclusive and complete");
    end
  end

  task automatic measured_pulse(input realtime start_time);
    integer count_before;
    integer good_before;
    integer expected;
    begin
      #(start_time - $realtime);
      count_before = event_count;
      good_before = good_count;
      expected = $rtoi(start_time * 100.0);
      trigger_in = 1'b1;
      #32;
      trigger_in = 1'b0;
      #30;
      if (event_count != count_before + 1 || good_count != good_before + 1)
        $fatal(1, "32 ns trigger did not produce exactly one good event at %0.3f ns", start_time);
      if (last_timestamp < expected - 1 || last_timestamp > expected + 1)
        $fatal(1, "Timestamp mismatch: expected=%0d actual=%0d units of 10ps", expected, last_timestamp);
    end
  endtask

  initial begin
    #17 rst_n = 1'b1;
    #15;
    if (ready) $fatal(1, "Capture ready before the first sampled DAC reference");
    #4;
    if (!ready) $fatal(1, "Capture did not acquire the falling DAC reference");

    // Five observed 4 ns bins, plus capture immediately around a DAC boundary.
    for (phase = 0; phase < 5; phase = phase + 1)
      measured_pulse(40.321 + phase * 84.0);
    measured_pulse(459.999);
    measured_pulse(540.001);
    measured_pulse(624.999);

    @(negedge sample_clk);
    calib_wr_en = 1'b1;
    calib_wr_addr = 10'd17;
    calib_wr_data = 16'd345;
    @(negedge sample_clk);
    calib_wr_en = 1'b0;
    calib_rd_addr = 10'd17;
    #0.001;
    if (calib_rd_data !== 16'd345) $fatal(1, "Calibration readback mismatch");

    // Fault injection tests classification without replacing timestamp state.
    previous_count = event_count;
    fault_sample = {TAPS{1'b1}};
    force dut.sampled = fault_sample;
    #30;
    release dut.sampled;
    #30;
    if (event_count != previous_count + 1 || overflow_count != 1)
      $fatal(1, "Saturation did not produce one overflow event");

    previous_count = event_count;
    fault_sample = {{(TAPS-8){1'b0}}, 8'b01110011};
    force dut.sampled = fault_sample;
    #30;
    release dut.sampled;
    #30;
    if (event_count != previous_count + 1 || bubble_count != 1 || event_tap != 0)
      $fatal(1, "Malformed thermometer code did not produce a clean bubble event");

    measured_pulse(880.321);
    if (overflow_count != 1 || bubble_count != 1)
      $fatal(1, "A valid trigger after faults failed to rearm");
    $display("PASS: timestamp reference, five 4ns bins, wrap, rearm, calibration readback and fault classification");
    $finish;
  end

  initial begin
    #2000;
    $fatal(1, "TIMEOUT");
  end
endmodule
