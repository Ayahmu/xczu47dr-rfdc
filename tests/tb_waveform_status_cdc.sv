`timescale 1ns/1ps
module tb_waveform_status_cdc;
  localparam integer WIDTH=16;
  reg ddr_clk=0; always #5 ddr_clk=~ddr_clk;
  reg dac_clk=0; always #3.5 dac_clk=~dac_clk;
  reg ddr_rst_n=0, dac_rst_n=0;
  reg request_ddr=0;
  reg [WIDTH-1:0] source_data_dac=16'h1234;
  wire request_ready_ddr, snapshot_valid_ddr;
  wire [WIDTH-1:0] snapshot_data_ddr;
  waveform_status_cdc #(.WIDTH(WIDTH)) dut (
      .ddr_clk(ddr_clk), .ddr_rst_n(ddr_rst_n), .request_ddr(request_ddr),
      .request_ready_ddr(request_ready_ddr), .snapshot_valid_ddr(snapshot_valid_ddr),
      .snapshot_data_ddr(snapshot_data_ddr), .dac_clk(dac_clk), .dac_rst_n(dac_rst_n),
      .source_data_dac(source_data_dac));
  integer failures=0;
  task ddr_tick; begin @(posedge ddr_clk); #1; end endtask
  initial begin
    repeat(3) ddr_tick; ddr_rst_n=1; dac_rst_n=1;
    repeat(3) ddr_tick;
    if (!request_ready_ddr) begin $display("FAIL: CDC not initially ready"); failures=failures+1; end
    request_ddr=1; ddr_tick; request_ddr=0;
    // Allow the request toggle to reach the source before changing the live
    // source record; the captured result must remain immutable afterward.
    repeat(5) @(posedge dac_clk);
    source_data_dac=16'hbeef;
    repeat(20) begin
      ddr_tick;
      if (snapshot_valid_ddr && snapshot_data_ddr !== 16'h1234) begin
        $display("FAIL: first snapshot changed to %h", snapshot_data_ddr); failures=failures+1;
      end
    end
    if (!request_ready_ddr) begin $display("FAIL: CDC did not complete first request"); failures=failures+1; end
    request_ddr=1; ddr_tick; request_ddr=0;
    repeat(20) ddr_tick;
    if (!request_ready_ddr || snapshot_data_ddr !== 16'hbeef) begin
      $display("FAIL: second snapshot ready=%b data=%h", request_ready_ddr, snapshot_data_ddr); failures=failures+1;
    end
    if (failures) $fatal(1,"%0d status CDC failures", failures);
    $display("PASS: waveform status snapshot CDC holds a coherent source record");
    $finish;
  end
  initial begin #2000; $fatal(1,"timeout"); end
endmodule
