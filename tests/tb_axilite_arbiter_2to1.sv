`timescale 1ns/1ps

module tb_axilite_arbiter_2to1;
  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  reg [17:0] s0_awaddr=0, s0_araddr=0, s1_awaddr=0, s1_araddr=0;
  reg s0_awvalid=0, s0_wvalid=0, s0_bready=1, s0_arvalid=0, s0_rready=1;
  reg s1_awvalid=0, s1_wvalid=0, s1_bready=1, s1_arvalid=0, s1_rready=1;
  reg [31:0] s0_wdata=0, s1_wdata=0;
  reg [3:0] s0_wstrb=4'hf, s1_wstrb=4'hf;
  wire s0_awready, s0_wready, s0_bvalid, s0_arready, s0_rvalid;
  wire s1_awready, s1_wready, s1_bvalid, s1_arready, s1_rvalid;
  wire [1:0] s0_bresp, s0_rresp, s1_bresp, s1_rresp;
  wire [31:0] s0_rdata, s1_rdata;

  wire [17:0] m_awaddr, m_araddr;
  wire m_awvalid, m_wvalid, m_bready, m_arvalid, m_rready;
  wire [31:0] m_wdata;
  wire [3:0] m_wstrb;
  reg m_awready=1, m_wready=1, m_bvalid=0, m_arready=1, m_rvalid=0;
  reg [1:0] m_bresp=0, m_rresp=0;
  reg [31:0] m_rdata=32'h12345678;

  axilite_arbiter_2to1 dut (
    .clk(clk), .rst_n(rst_n),
    .s0_awaddr(s0_awaddr), .s0_awvalid(s0_awvalid), .s0_awready(s0_awready),
    .s0_wdata(s0_wdata), .s0_wstrb(s0_wstrb), .s0_wvalid(s0_wvalid), .s0_wready(s0_wready),
    .s0_bresp(s0_bresp), .s0_bvalid(s0_bvalid), .s0_bready(s0_bready),
    .s0_araddr(s0_araddr), .s0_arvalid(s0_arvalid), .s0_arready(s0_arready),
    .s0_rdata(s0_rdata), .s0_rresp(s0_rresp), .s0_rvalid(s0_rvalid), .s0_rready(s0_rready),
    .s1_awaddr(s1_awaddr), .s1_awvalid(s1_awvalid), .s1_awready(s1_awready),
    .s1_wdata(s1_wdata), .s1_wstrb(s1_wstrb), .s1_wvalid(s1_wvalid), .s1_wready(s1_wready),
    .s1_bresp(s1_bresp), .s1_bvalid(s1_bvalid), .s1_bready(s1_bready),
    .s1_araddr(s1_araddr), .s1_arvalid(s1_arvalid), .s1_arready(s1_arready),
    .s1_rdata(s1_rdata), .s1_rresp(s1_rresp), .s1_rvalid(s1_rvalid), .s1_rready(s1_rready),
    .m_awaddr(m_awaddr), .m_awvalid(m_awvalid), .m_awready(m_awready),
    .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wvalid(m_wvalid), .m_wready(m_wready),
    .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
    .m_araddr(m_araddr), .m_arvalid(m_arvalid), .m_arready(m_arready),
    .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rvalid(m_rvalid), .m_rready(m_rready)
  );

  task check(input condition, input string message);
    begin if (!condition) begin $display("FAIL: %s", message); $finish; end end
  endtask

  initial begin
    repeat (3) @(negedge clk); rst_n=1;

    // Master 0 starts with AW only. The grant must remain master 0 until B.
    s0_awaddr=18'h00120; s0_awvalid=1;
    @(negedge clk); s0_awvalid=0;
    s1_araddr=18'h00200; s1_arvalid=1;
    s1_wdata=32'hbad0bad0; s1_wvalid=1;
    s0_wdata=32'hcafe1234; s0_wvalid=1;
    #1;
    check(m_wvalid && m_wdata == 32'hcafe1234, "write data switched away from the granted master");
    check(!m_arvalid && !s1_arready && !s1_wready, "another master entered before write response");
    @(negedge clk); s0_wvalid=0;
    m_bvalid=1;
    #1; check(s0_bvalid && !s1_bvalid, "write response was routed to the wrong master");
    @(negedge clk); m_bvalid=0; s1_wvalid=0;

    // The queued master-1 read may proceed only after the complete write.
    #1; check(m_arvalid && m_araddr == 18'h00200 && s1_arready, "queued read did not receive the next grant");
    @(negedge clk); s1_arvalid=0;
    s0_awaddr=18'h00300; s0_awvalid=1; s0_wvalid=1;
    #1; check(!m_awvalid && !s0_awready && !s0_wready, "write interrupted an active read transaction");
    m_rvalid=1;
    #1; check(s1_rvalid && s1_rdata == 32'h12345678 && !s0_rvalid, "read response was routed to the wrong master");
    @(negedge clk); m_rvalid=0;

    #1;
    check(m_awvalid && m_wvalid && m_awaddr == 18'h00300, "queued write did not proceed after read response");
    $display("PASS: AXI-Lite arbiter locks each write and read transaction to one master");
    $finish;
  end
endmodule
