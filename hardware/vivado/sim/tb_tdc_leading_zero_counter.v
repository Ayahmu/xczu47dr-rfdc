// Testbench for tdc_leading_zero_counter: verifies thermometer-to-binary conversion
// with various test patterns.

`timescale 1ns/1ps

module tb_tdc_leading_zero_counter;

  localparam WIDTH = 256;
  localparam CLK_PERIOD = 20;  // 50 MHz

  reg                      clk;
  reg                      rst_n;
  reg  [WIDTH-1:0]         thermometer_in;
  reg                      valid_in;
  wire [$clog2(WIDTH)-1:0] zero_count;
  wire                     valid_out;
  wire                     overflow;

  // DUT
  tdc_leading_zero_counter #(
      .WIDTH(WIDTH)
  ) dut (
      .clk            (clk),
      .rst_n          (rst_n),
      .thermometer_in (thermometer_in),
      .valid_in       (valid_in),
      .zero_count     (zero_count),
      .valid_out      (valid_out),
      .overflow       (overflow)
  );

  // Clock generation
  initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
  end

  // Test vectors
  task check_result;
    input [7:0] expected_count;
    input expected_valid;
    input expected_overflow;
    begin
      @(posedge clk);
      #1;
      repeat(3) @(posedge clk);  // Wait for pipeline (3 stages)
      #1;
      if (valid_out !== expected_valid) begin
        $error("FAIL: valid_out = %b, expected %b", valid_out, expected_valid);
      end else if (expected_valid && zero_count !== expected_count) begin
        $error("FAIL: zero_count = %d, expected %d", zero_count, expected_count);
      end else if (overflow !== expected_overflow) begin
        $error("FAIL: overflow = %b, expected %b", overflow, expected_overflow);
      end else begin
        $display("PASS: thermometer=%h -> count=%d valid=%b overflow=%b",
                 thermometer_in[15:0], zero_count, valid_out, overflow);
      end
    end
  endtask

  // Stimulus
  initial begin
    $display("=== TDC Leading Zero Counter Test ===");
    rst_n = 0;
    thermometer_in = 0;
    valid_in = 0;
    repeat(5) @(posedge clk);
    rst_n = 1;
    repeat(2) @(posedge clk);

    // Test case 1: all zeros (overflow)
    thermometer_in = 256'h0;
    valid_in = 1;
    check_result(8'd0, 1'b0, 1'b1);

    // Test case 2: first bit set (count = 0)
    thermometer_in = 256'h1;
    valid_in = 1;
    check_result(8'd0, 1'b1, 1'b0);

    // Test case 3: second bit set (count = 1)
    thermometer_in = 256'h3;  // 0000...0011
    valid_in = 1;
    check_result(8'd1, 1'b1, 1'b0);

    // Test case 4: bit 16 set (first 17 bits are 1: [16:0])
    thermometer_in = 256'h0;
    thermometer_in[16:0] = 17'h1FFFF;  // bits 0-16 all set
    valid_in = 1;
    check_result(8'd16, 1'b1, 1'b0);

    // Test case 5: bit 100 is highest set (thermometer: [100:0]=1, [255:101]=0)
    thermometer_in = 256'h0;
    thermometer_in[100:0] = {101{1'b1}};  // bits 0-100 all set
    valid_in = 1;
    check_result(8'd100, 1'b1, 1'b0);

    // Test case 6: bit 200 is highest set
    thermometer_in = 256'h0;
    thermometer_in[200:0] = {201{1'b1}};  // bits 0-200 all set
    valid_in = 1;
    check_result(8'd200, 1'b1, 1'b0);

    repeat(5) @(posedge clk);
    $display("=== TDC Leading Zero Counter Test Complete ===");
    $finish;
  end

  // Timeout watchdog
  initial begin
    #10000;
    $error("TIMEOUT: test did not complete");
    $finish;
  end

endmodule
