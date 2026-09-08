`timescale 1ns/1ps

module tb_iq_fractional_delay_8ppc;
  reg clk = 0;
  always #10 clk = ~clk;
  reg rst_n = 0;
  reg clear = 0;
  reg config_valid = 0;
  reg [2:0] delay_samples = 0;
  reg [5:0] fractional_phase = 0;
  reg [255:0] source_data = 0;
  reg source_valid = 0;
  wire [255:0] out_data;
  wire busy;
  wire clip_pulse;
  iq_fractional_delay_8ppc dut (.*);

  reg [1023:0] vector_path;
  reg [11:0] controls;
  reg [255:0] vector_source;
  reg [255:0] expected_data;
  integer expected_busy, expected_clip;
  integer fd, fields, line = 0;
  initial begin
    if (!$value$plusargs("VECTORS=%s", vector_path))
      $fatal(1, "VECTORS plusarg is required");
    fd = $fopen(vector_path, "r");
    if (fd == 0) $fatal(1, "could not open vectors");
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    while (!$feof(fd)) begin
      fields = $fscanf(fd, "%h %h %h %d %d\n", controls, vector_source,
                        expected_data, expected_busy, expected_clip);
      if (fields != 5) $fatal(1, "invalid vector after line %0d", line);
      @(negedge clk);
      config_valid = controls[0];
      clear = controls[1];
      fractional_phase = controls[7:2];
      delay_samples = controls[10:8];
      source_valid = controls[11];
      source_data = vector_source;
      @(posedge clk);
      #1;
      line = line + 1;
      if ((out_data !== expected_data) || (busy !== expected_busy[0]) ||
          (clip_pulse !== expected_clip[0])) begin
        $display("line=%0d controls=%h", line, controls);
        $display("data expected=%h actual=%h", expected_data, out_data);
        $display("busy expected=%0d actual=%b clip expected=%0d actual=%b",
                 expected_busy, busy, expected_clip, clip_pulse);
        $fatal(1, "FIR mismatch");
      end
    end
    $fclose(fd);
    $display("PASS: %0d FIR cycles match independent integer convolution", line);
    $finish;
  end
endmodule
