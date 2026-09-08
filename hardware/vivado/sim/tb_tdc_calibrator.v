// Testbench for tdc_calibrator: verifies table lookup and write interface.

`timescale 1ns/1ps

module tb_tdc_calibrator;

  localparam TAPS = 256;
  localparam CALIB_ADDR_WIDTH = 10;
  localparam CLK_PERIOD = 20;

  reg                         clk;
  reg                         rst_n;
  reg  [$clog2(TAPS)-1:0]     tap_index_raw;
  reg                         valid_in;
  reg                         calib_wr_en;
  reg  [CALIB_ADDR_WIDTH-1:0] calib_wr_addr;
  reg  [15:0]                 calib_wr_data;
  wire [15:0]                 time_ps_x10;
  wire                        valid_out;

  // DUT
  tdc_calibrator #(
      .TAPS(TAPS),
      .CALIB_ADDR_WIDTH(CALIB_ADDR_WIDTH)
  ) dut (
      .clk            (clk),
      .rst_n          (rst_n),
      .tap_index_raw  (tap_index_raw),
      .valid_in       (valid_in),
      .calib_wr_en    (calib_wr_en),
      .calib_wr_addr  (calib_wr_addr),
      .calib_wr_data  (calib_wr_data),
      .time_ps_x10    (time_ps_x10),
      .valid_out      (valid_out)
  );

  // Clock
  initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
  end

  // Test task
  task read_calibrated;
    input [7:0] tap;
    input [15:0] expected_time;
    begin
      @(posedge clk);
      tap_index_raw = tap;
      valid_in = 1;
      @(posedge clk);
      #1;  // Check on the cycle where valid_in was high
      $display("DEBUG: After valid_in=1 cycle: valid_out=%b time_ps_x10=%d", valid_out, time_ps_x10);
      if (!valid_out) begin
        $error("FAIL: valid_out should be high for tap %d", tap);
      end else if (time_ps_x10 !== expected_time) begin
        $error("FAIL: tap %d -> time=%d, expected %d", tap, time_ps_x10, expected_time);
      end else begin
        $display("PASS: tap %d -> %d × 10ps = %d ps", tap, time_ps_x10, time_ps_x10 * 10);
      end
      valid_in = 0;
      tap_index_raw = 0;
    end
  endtask

  task write_calibration;
    input [9:0] addr;
    input [15:0] data;
    begin
      @(posedge clk);
      calib_wr_en = 1;
      calib_wr_addr = addr;
      calib_wr_data = data;
      @(posedge clk);
      calib_wr_en = 0;
      $display("INFO: wrote calib[%d] = %d", addr, data);
    end
  endtask

  // Stimulus
  initial begin
    $display("=== TDC Calibrator Test ===");
    rst_n = 0;
    tap_index_raw = 0;
    valid_in = 0;
    calib_wr_en = 0;
    calib_wr_addr = 0;
    calib_wr_data = 0;
    repeat(5) @(posedge clk);
    rst_n = 1;
    repeat(2) @(posedge clk);

    // Test 1: read default calibration (linear, 30ps per tap = 3 × 10ps)
    $display("--- Test default calibration ---");
    read_calibrated(8'd0, 16'd0);       // tap 0 -> 0 ps
    read_calibrated(8'd10, 16'd30);     // tap 10 -> 300 ps
    read_calibrated(8'd100, 16'd300);   // tap 100 -> 3000 ps

    // Test 2: write custom calibration and read back
    $display("--- Test custom calibration ---");
    write_calibration(10'd0, 16'd0);
    write_calibration(10'd10, 16'd35);   // 350 ps (non-linear)
    write_calibration(10'd100, 16'd310); // 3100 ps

    read_calibrated(8'd0, 16'd0);
    read_calibrated(8'd10, 16'd35);
    read_calibrated(8'd100, 16'd310);

    // Test 3: verify unchanged entries still have default values
    read_calibrated(8'd50, 16'd150);  // 50 × 3 = 150

    repeat(5) @(posedge clk);
    $display("=== TDC Calibrator Test Complete ===");
    $finish;
  end

  // Timeout
  initial begin
    #5000;
    $error("TIMEOUT");
    $finish;
  end

endmodule
