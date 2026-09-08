`timescale 1ns/1ps
module tb_udp_writer_fifo_collision;
  reg clk = 0, rst_n = 0;
  always #5 clk = !clk;
  reg udp_valid = 0, udp_last = 0;
  reg [63:0] udp_data = 0;
  reg awready = 0, wready = 0, bvalid = 0;
  wire awvalid, wvalid;
  wire [63:0] awaddr;
  wire [255:0] wdata;
  wire [15:0] fifo_count;
  wire [31:0] drops, writes;
  integer index;
  udp_waveform_ddr_writer dut (
      .clk(clk), .rst_n(rst_n), .udp_tvalid(udp_valid), .udp_tdata(udp_data), .udp_tlast(udp_last),
      .m_axi_awready(awready), .m_axi_awvalid(awvalid), .m_axi_awaddr(awaddr),
      .m_axi_wready(wready), .m_axi_wvalid(wvalid), .m_axi_wdata(wdata),
      .m_axi_bvalid(bvalid), .m_axi_bresp(2'b00),
      .dbg_fifo_count_o(fifo_count), .dbg_drop_count_o(drops), .dbg_write_count(writes));

  function [255:0] expected_data(input integer id);
    expected_data = {64'h400 + id, 64'h300 + id, 64'h200 + id, 64'h100 + id};
  endfunction
  task word(input [63:0] data, input last);
    begin
      @(negedge clk); udp_valid = 1; udp_data = data; udp_last = last;
      @(posedge clk); #1; udp_valid = 0; udp_last = 0;
    end
  endtask
  task packet(input integer id);
    begin
      word(64'h5741564544445230, 0);
      word(64'h1000 + id * 32, 0);
      word(64'h100 + id, 0); word(64'h200 + id, 0);
      word(64'h300 + id, 0); word(64'h400 + id, 1);
    end
  endtask
  task pending(input integer id);
    begin
      wait (awvalid && wvalid); #1;
      if (awaddr !== 64'h1000 + id * 32 || wdata !== expected_data(id))
        $fatal(1, "FIFO order/data mismatch for record %0d", id);
    end
  endtask
  task retire;
    begin
      @(negedge clk); awready = 1; wready = 1;
      @(negedge clk); awready = 0; wready = 0; bvalid = 1;
      @(negedge clk); bvalid = 0;
    end
  endtask
  initial begin
    #2; repeat (3) @(negedge clk); rst_n = 1;
    for (index = 0; index < 17; index = index + 1) packet(index);
    if (fifo_count !== 16 || writes !== 17 || drops !== 0)
      $fatal(1, "FIFO did not fill behind stalled AXI write");
    pending(0);
    packet(17);
    if (fifo_count !== 16 || writes !== 17 || drops !== 1)
      $fatal(1, "Full FIFO admission mismatch");
    pending(0);

    @(negedge clk); awready = 1; wready = 1;
    @(negedge clk); awready = 0; wready = 0;
    word(64'h5741564544445230, 0);
    word(64'h1000 + 18 * 32, 0);
    word(64'h100 + 18, 0); word(64'h200 + 18, 0);
    // Release the prior response one cycle before the final incoming word.
    @(negedge clk); udp_valid = 1; udp_data = 64'h300 + 18; bvalid = 1;
    @(posedge clk); #1; udp_valid = 0; bvalid = 0;
    word(64'h400 + 18, 1);
    if (fifo_count !== 16 || writes !== 18 || drops !== 1)
      $fatal(1, "Simultaneous full FIFO push/pop mismatch");
    for (index = 1; index < 17; index = index + 1) begin
      pending(index); retire();
    end
    pending(18); retire();
    repeat (4) @(negedge clk);
    if (fifo_count !== 0 || awvalid || wvalid) $fatal(1, "FIFO failed to drain");

    packet(99); packet(100); pending(99);
    @(negedge clk); rst_n = 0;
    repeat (3) @(negedge clk); rst_n = 1;
    repeat (4) @(negedge clk);
    if (fifo_count !== 0 || awvalid || wvalid) $fatal(1, "Reset exposed stale queue data");
    packet(101); pending(101); retire();
    $display("PASS: writer FIFO preserves old data on full push/pop and resets admission");
    $finish;
  end
  initial begin #100000; $fatal(1, "FIFO test timeout"); end
endmodule
