`timescale 1ns/1ps
module tb_tdc_register_service;
  reg ddr_clk = 0, sample_clk = 0;
  always #1.667 ddr_clk = !ddr_clk;
  always #2.5 sample_clk = !sample_clk;
  reg rst_n = 0, reg_valid = 0, reg_write = 0, armed = 0;
  reg [15:0] address = 0;
  reg [31:0] data = 0;
  wire reg_ready;
  wire [31:0] result;
  wire [15:0] error;
  wire lut_write, enabled, cal_source, carrier, calibrated, clear_toggle;
  wire [10:0] lut_addr, lut_read_addr;
  wire [15:0] lut_data;
  wire signed [15:0] offset;
  reg [15:0] lut [0:2047];
  integer n, writes = 0, timeout;
  always @(posedge sample_clk) if (lut_write) begin lut[lut_addr] <= lut_data; writes = writes + 1; end
  tdc_register_service dut (
      .ddr_clk(ddr_clk), .ddr_rst_n(rst_n), .sample_clk(sample_clk), .sample_rst_n(rst_n),
      .reg_valid(reg_valid), .reg_write(reg_write), .reg_addr(address), .reg_wdata(data),
      .reg_ready(reg_ready), .reg_rdata(result), .reg_error(error), .armed_dac(armed),
      .reference_ready(1'b1), .monitor_toggle(1'b0), .monitor_data(256'd0),
      .event_valid(1'b0), .event_good(1'b0), .event_overflow(1'b0), .event_bubble(1'b0),
      .event_epoch(32'd0), .event_phase_10ps(11'd0), .event_tap(11'd0),
      .calib_wr_en(lut_write), .calib_wr_addr(lut_addr), .calib_wr_data(lut_data),
      .calib_rd_addr(lut_read_addr), .calib_rd_data(lut[lut_read_addr]),
      .compensation_enable(enabled), .calibration_source(cal_source),
      .carrier_correction_enable(carrier), .calibration_valid(calibrated),
      .phase_offset_10ps(offset), .clear_statistics_toggle(clear_toggle)
  );
  task transaction(input bit wr, input [15:0] a, input [31:0] d, input [15:0] expected_error);
    begin
      @(negedge ddr_clk); reg_write = wr; address = a; data = d; reg_valid = 1;
      timeout = 0;
      while (!reg_ready && timeout < 100) begin @(negedge ddr_clk); timeout = timeout + 1; end
      if (!reg_ready || error !== expected_error)
        $fatal(1, "Register %h error=%h expected=%h ready=%b", a, error, expected_error, reg_ready);
      // A slow master may hold valid after completion; it must not replay.
      repeat(4) @(negedge ddr_clk);
      reg_valid = 0;
      repeat(3) @(negedge ddr_clk);
    end
  endtask
  initial begin
    for(n=0;n<2048;n=n+1) lut[n] = 0;
    #40 rst_n = 1;
    #10400;
    transaction(0,16'h0000,0,0);
    if (result != 32'h54444301) $fatal(1,"Bad identity");
    transaction(1,16'h0004,1,3);
    if(enabled) $fatal(1,"Enabled without calibration");
    transaction(1,16'h0058,2,3);
    for(n=0;n<2048;n=n+1) transaction(1,16'h1000+n*4,(n*500)/2048,0);
    if(writes != 2048) $fatal(1,"Calibration writes duplicated/lost: %0d",writes);
    transaction(0,16'h2ffc,0,0);
    if(result != 499) $fatal(1,"LUT readback mismatch");
    transaction(1,16'h0058,2,0);
    if(!calibrated) $fatal(1,"Complete calibration failed to commit");
    transaction(1,16'h0004,1,0);
    if(!enabled) $fatal(1,"Calibrated enable failed");
    transaction(1,16'h1000,0,4);
    transaction(1,16'h0004,0,0);
    armed = 1; #30;
    transaction(1,16'h000c,17,4);
    armed = 0; #30;
    transaction(1,16'h000c,32'hfffffff7,0);
    if(offset != -9) $fatal(1,"Signed phase offset mismatch");
    transaction(1,16'h1000,0,0);
    if(calibrated) $fatal(1,"Changed table remained calibrated");
    transaction(1,16'h1008,2,3);
    transaction(0,16'h0002,0,3);
    $display("PASS: asynchronous CSR completion, no replay, LUT commit/readback, armed protection and signed offset");
    $finish;
  end
  initial begin #1000000; $fatal(1,"TIMEOUT"); end
endmodule
