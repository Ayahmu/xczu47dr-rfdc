`timescale 1ns/1ps
module tb_tdc_async_fifo;
  reg wr_clk = 0, rd_clk = 0, rst_n = 1;
  always #2.5 wr_clk = !wr_clk;
  always #10 rd_clk = !rd_clk;
  wire rd_valid, wr_ready;
  wire [56:0] rd_data;
  time last_read_edge;
  integer phase;
  tdc_async_fifo #(.WIDTH(57)) dut (
      .wr_clk(wr_clk), .rd_clk(rd_clk), .rst_n(rst_n),
      .wr_data(57'h1234567), .wr_valid(1'b0), .wr_ready(wr_ready),
      .rd_data(rd_data), .rd_valid(rd_valid), .rd_ready(1'b1));
  always @(posedge rd_clk) last_read_edge = $time;
  always @(posedge rd_valid) begin
    if ($time != last_read_edge) $fatal(1, "Read admission rose between DAC edges");
  end
  initial begin
    for (phase = 0; phase < 20; phase = phase + 1) begin
      #1 rst_n = 0;
      #0.001;
      if (rd_valid !== 0) $fatal(1, "Reset must suppress stale FIFO data immediately");
      @(negedge rd_clk);
      #(phase + 0.5) rst_n = 1;
      #0.001;
      if (rd_valid !== 0) $fatal(1, "Asynchronous release exposed stale FIFO data");
      repeat (2) begin
        @(posedge rd_clk); #0.001;
        if (rd_valid !== 0) $fatal(1, "Read admission released too early");
      end
      @(posedge rd_clk); #0.001;
      if (rd_valid !== 1) $fatal(1, "Read admission did not recover");
    end
    $display("PASS: FIFO read admission releases on rd_clk and asserts asynchronously");
    $finish;
  end
endmodule

// Adversarial FIFO status isolates the wrapper's reset admission contract:
// stale nonempty data must be blocked even before the vendor busy flag rises.
module xpm_fifo_async #(
    parameter FIFO_MEMORY_TYPE = "distributed", FIFO_WRITE_DEPTH = 16,
    WRITE_DATA_WIDTH = 57, READ_DATA_WIDTH = 57, READ_MODE = "fwft",
    FIFO_READ_LATENCY = 0, CDC_SYNC_STAGES = 2, RELATED_CLOCKS = 0,
    ECC_MODE = "no_ecc", WR_DATA_COUNT_WIDTH = 5, RD_DATA_COUNT_WIDTH = 5,
    USE_ADV_FEATURES = "0000"
) (
    input rst, wr_clk, rd_clk, wr_en, rd_en, sleep, injectsbiterr, injectdbiterr,
    input [WRITE_DATA_WIDTH-1:0] din,
    output [READ_DATA_WIDTH-1:0] dout,
    output full, empty, wr_rst_busy, rd_rst_busy, almost_empty, almost_full,
    data_valid, dbiterr, overflow, prog_empty, prog_full, sbiterr, underflow, wr_ack,
    output [RD_DATA_COUNT_WIDTH-1:0] rd_data_count,
    output [WR_DATA_COUNT_WIDTH-1:0] wr_data_count
);
  assign full = 0;
  assign empty = 0;
  assign wr_rst_busy = 0;
  assign rd_rst_busy = 0;
  assign dout = 57'h1234567;
endmodule
