`timescale 1ns/1ps

module tb_tdc_encoder;

  localparam integer TAPS = 256;
  localparam integer CLK_PERIOD_PS = 5000;

  reg                      clk;
  reg                      rst_n;
  reg  [TAPS-1:0]          taps_in;
  reg  [1:0]               sample_slot_in;
  wire [$clog2(TAPS)-1:0]  tap_index;
  wire [1:0]               sample_slot_out;
  wire                     valid;
  wire                     overflow;
  wire                     metastable;
  integer                  valid_count;
  integer                  overflow_count;
  integer                  metastable_count;

  tdc_encoder #(
      .TAPS(TAPS)
  ) dut (
      .clk_sample     (clk),
      .rst_n          (rst_n),
      .taps_in        (taps_in),
      .sample_slot_in (sample_slot_in),
      .tap_index      (tap_index),
      .sample_slot_out(sample_slot_out),
      .valid          (valid),
      .overflow       (overflow),
      .metastable     (metastable)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD_PS/2 * 1ps) clk = ~clk;
  end

  always @(posedge clk) begin
    #1ps;
    if (valid) begin
      valid_count = valid_count + 1;
    end
    if (overflow) begin
      overflow_count = overflow_count + 1;
    end
    if (metastable) begin
      metastable_count = metastable_count + 1;
    end
  end

  task drive_pattern;
    input [TAPS-1:0] pattern;
    input [1:0] slot;
    begin
      @(negedge clk);
      taps_in = pattern;
      sample_slot_in = slot;
    end
  endtask

  initial begin
    rst_n = 1'b0;
    taps_in = {TAPS{1'b0}};
    sample_slot_in = 2'd0;
    valid_count = 0;
    overflow_count = 0;
    metastable_count = 0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    repeat (5) @(posedge clk);
    if (valid_count != 0 || overflow_count != 0 || metastable_count != 0) begin
      $fatal(1, "Idle zero samples must not report a TDC event");
    end

    drive_pattern({{(TAPS-11){1'b0}}, 11'h7ff}, 2'd2);
    repeat (8) @(posedge clk);
    if (valid_count != 1 || overflow_count != 0 || metastable_count != 0) begin
      $fatal(1, "A sustained thermometer code must produce exactly one valid event");
    end
    if (tap_index !== 8'd10 || sample_slot_out !== 2'd2) begin
      $fatal(1, "Fine tap and coarse slot must come from the same sample");
    end

    drive_pattern({TAPS{1'b0}}, 2'd0);
    repeat (3) @(posedge clk);
    drive_pattern({{(TAPS-5){1'b0}}, 5'h1f}, 2'd1);
    repeat (6) @(posedge clk);
    if (valid_count != 2 || tap_index !== 8'd4 || sample_slot_out !== 2'd1) begin
      $fatal(1, "Returning to zero must re-arm the encoder for the next trigger");
    end

    drive_pattern({TAPS{1'b0}}, 2'd0);
    repeat (3) @(posedge clk);
    drive_pattern({TAPS{1'b1}}, 2'd3);
    repeat (6) @(posedge clk);
    if (overflow_count != 1 || valid_count != 2 || metastable_count != 0) begin
      $fatal(1, "All-one saturation must produce one overflow event and no valid result");
    end

    drive_pattern({TAPS{1'b0}}, 2'd0);
    repeat (3) @(posedge clk);
    drive_pattern({{(TAPS-6){1'b0}}, 6'b11_1011}, 2'd0);
    repeat (6) @(posedge clk);
    if (metastable_count != 1 || valid_count != 2 || overflow_count != 1) begin
      $fatal(1, "A thermometer-code bubble must produce one metastability event");
    end

    $display("PASS: TDC encoder one-shot event semantics verified");
    $finish;
  end

  initial begin
    #2us;
    $fatal(1, "TIMEOUT");
  end

endmodule
