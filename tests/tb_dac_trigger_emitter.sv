`timescale 1ns/1ps

// dac_trigger_emitter: DDR-domain request must produce exactly one gated pulse
// of the configured width in the DAC domain.
module tb_dac_trigger_emitter;
  reg ddr_clk = 1'b0;
  reg dac_clk = 1'b0;
  reg rst_n = 1'b0;
  reg req = 1'b0;
  reg allowed = 1'b1;
  wire pulse;
  wire [31:0] count;
  integer errors = 0;
  integer high_len = 0;
  integer pulses = 0;
  reg pulse_prev = 1'b0;

  always #2.5 ddr_clk = ~ddr_clk;   // 200 MHz DDR UI
  always #10  dac_clk = ~dac_clk;   // 50 MHz DAC AXIS

  dac_trigger_emitter #(.HIGH_CYCLES(4)) dut (
      .ddr_clk(ddr_clk), .ddr_rst_n(rst_n),
      .emit_request_ddr(req),
      .dac_clk(dac_clk), .dac_rst_n(rst_n),
      .emit_allowed(allowed),
      .pulse_out(pulse), .pulse_count(count)
  );

  always @(posedge dac_clk) begin
    if (pulse) high_len = high_len + 1;
    if (pulse && !pulse_prev) pulses = pulses + 1;
    pulse_prev <= pulse;
  end

  task request;
    begin
      @(posedge ddr_clk); req = 1'b1;
      @(posedge ddr_clk); req = 1'b0;
      repeat (14) @(posedge dac_clk);
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
    repeat (4) @(posedge dac_clk);
    rst_n = 1'b1;
    repeat (4) @(posedge dac_clk);

    // 1. One request -> one pulse, 5 DAC cycles wide (HIGH_CYCLES + the cycle
    //    the request is consumed on).
    high_len = 0; pulses = 0;
    request();
    check(pulses == 1, "one request did not make exactly one pulse");
    check(high_len == 5, "pulse width is not HIGH_CYCLES+1 DAC cycles");
    check(count == 32'd1, "pulse_count did not advance");

    // 2. A second request works the same way.
    high_len = 0; pulses = 0;
    request();
    check(pulses == 1 && high_len == 5, "second request misbehaved");
    check(count == 32'd2, "pulse_count did not reach 2");

    // 3. Gate closed: request is swallowed.
    allowed = 1'b0;
    high_len = 0; pulses = 0;
    request();
    check(pulses == 0 && high_len == 0, "closed gate still emitted a pulse");
    check(count == 32'd2, "closed gate advanced pulse_count");

    // 4. Gate reopened: emission resumes.
    allowed = 1'b1;
    high_len = 0; pulses = 0;
    request();
    check(pulses == 1 && count == 32'd3, "gate reopen did not resume emission");

    if (errors == 0)
      $display("PASS: dac_trigger_emitter emits one gated DAC-domain pulse per request");
    else
      $display("FAIL: dac_trigger_emitter had %0d error(s)", errors);
    $finish;
  end

  initial begin
    #50000;
    $display("FAIL: emitter test timed out");
    $finish;
  end
endmodule
