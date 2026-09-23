`timescale 1ns/1ps
// Test-only probe: does the real axis_async_fifo_256 deliver every word of a
// short burst across the CDC after a short write-domain-only reset pulse?
module tb_fifo_publish_probe;
  // Write domain: 250 MHz (4 ns).  Read domain: 50 MHz (20 ns), matching the
  // clock ratio seen in the Top-level end-to-end run.
  reg wr_clk = 0; always #2 wr_clk = ~wr_clk;
  reg rd_clk = 0; always #10 rd_clk = ~rd_clk;

  reg wrstn = 0;
  reg [255:0] tdata = 0;
  reg tvalid = 0;
  wire tready;
  reg [31:0] wcnt;
  wire pe, pf;

  reg [255:0] rdata;
  wire rvalid;
  reg rready = 1;

  axis_async_fifo_256 dut (
    .s_axis_aresetn(wrstn), .s_axis_aclk(wr_clk),
    .s_axis_tvalid(tvalid), .s_axis_tready(tready),
    .s_axis_tdata(tdata), .s_axis_tlast(1'b0),
    .m_axis_aclk(rd_clk), .m_axis_tvalid(rvalid), .m_axis_tready(rready),
    .m_axis_tdata(rdata), .m_axis_tlast(),
    .axis_wr_data_count(wcnt), .prog_empty(pe), .prog_full(pf)
  );

  integer rd_count = 0;
  always @(posedge rd_clk) begin
    if (rvalid && rready) begin
      $display("[%0t] READ word=%h wcnt=%0d", $time, rdata[63:0], wcnt);
      rd_count <= rd_count + 1;
    end
  end

  task wr_word(input [255:0] d);
    begin
      @(negedge wr_clk); tdata = d; tvalid = 1'b1;
      @(negedge wr_clk); tvalid = 1'b0;
    end
  endtask

  initial begin
    // Short write-domain-only reset pulse: 16 write clocks (64 ns), which is
    // what the Top-level clear handshake produces.
    repeat (16) @(negedge wr_clk);
    wrstn = 1'b1;
    repeat (200) @(negedge wr_clk);
    $display("[%0t] reset released, writing 4 words", $time);
    for (integer i = 0; i < 4; i = i + 1) wr_word(i + 1);
    repeat (200) @(negedge rd_clk);
    $display("[%0t] RESULT words_read=%0d wcnt=%0d", $time, rd_count, wcnt);
    if (rd_count != 4) $fatal(1, "FIFO delivered %0d of 4 words", rd_count);
    $display("PASS: async FIFO delivered all 4 words after a 16-cycle reset pulse");
    $finish;
  end
  initial begin #200000; $fatal(1, "probe timeout read=%0d", rd_count); end
endmodule
