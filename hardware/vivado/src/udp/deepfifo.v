// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2022.2 (win64) Build 3671981 Fri Oct 14 05:00:03 MDT 2022
// Date        : Wed May  6 15:48:53 2026
// Host        : USER-20230713DM running 64-bit major release  (build 9200)
// Command     : write_verilog -mode synth_stub deepfifo.v
// Design      : deepfifo
// Purpose     : Stub declaration of top-level module interface
// Device      : xczu47dr-ffvg1517-2-i
// --------------------------------------------------------------------------------

// This empty module with port declaration file causes synthesis tools to infer a black box for IP.
// The synthesis directives are for Synopsys Synplify support to prevent IO buffer insertion.
// Please paste the declaration into a Verilog source file or add the file as an additional source.
module deepfifo(clk, reset, fifo_pre_rd_en, fifo_pre_empty, 
  fifo_pre_dout, fifo_pre_rd_count, fifo_pre_rd_count2, ramwren, ramrden, mode, 
  fifo_post_wr_en, fifo_post_full, fifo_post_din, fifo_post_wr_count, axi_aresetn, 
  axi_awaddr, axi_awlen, axi_awsize, axi_awburst, axi_awvalid, axi_awready, axi_wdata, axi_wstrb, 
  axi_wlast, axi_wvalid, axi_wready, axi_bvalid, axi_bready, axi_araddr, axi_arlen, axi_arsize, 
  axi_arburst, axi_arvalid, axi_arready, axi_rdata, axi_rlast, axi_rvalid, axi_rready, 
  wr_addr_set, wr_addr, rd_addr_set, rd_addr)
/* synthesis syn_black_box black_box_pad_pin="clk,reset,fifo_pre_rd_en,fifo_pre_empty,fifo_pre_dout[511:0],fifo_pre_rd_count[9:0],fifo_pre_rd_count2[10:0],ramwren,ramrden,mode[1:0],fifo_post_wr_en,fifo_post_full,fifo_post_din[511:0],fifo_post_wr_count[9:0],axi_aresetn,axi_awaddr[32:0],axi_awlen[7:0],axi_awsize[2:0],axi_awburst[1:0],axi_awvalid,axi_awready,axi_wdata[511:0],axi_wstrb[63:0],axi_wlast,axi_wvalid,axi_wready,axi_bvalid,axi_bready,axi_araddr[32:0],axi_arlen[7:0],axi_arsize[2:0],axi_arburst[1:0],axi_arvalid,axi_arready,axi_rdata[511:0],axi_rlast,axi_rvalid,axi_rready,wr_addr_set,wr_addr[32:0],rd_addr_set,rd_addr[32:0]" */;
  input clk;
  input reset;
  output fifo_pre_rd_en;
  input fifo_pre_empty;
  input [511:0]fifo_pre_dout;
  input [9:0]fifo_pre_rd_count;
  input [10:0]fifo_pre_rd_count2;
  input ramwren;
  input ramrden;
  input [1:0]mode;
  output fifo_post_wr_en;
  input fifo_post_full;
  output [511:0]fifo_post_din;
  input [9:0]fifo_post_wr_count;
  output axi_aresetn;
  output [32:0]axi_awaddr;
  output [7:0]axi_awlen;
  output [2:0]axi_awsize;
  output [1:0]axi_awburst;
  output axi_awvalid;
  input axi_awready;
  output [511:0]axi_wdata;
  output [63:0]axi_wstrb;
  output axi_wlast;
  output axi_wvalid;
  input axi_wready;
  input axi_bvalid;
  output axi_bready;
  output [32:0]axi_araddr;
  output [7:0]axi_arlen;
  output [2:0]axi_arsize;
  output [1:0]axi_arburst;
  output axi_arvalid;
  input axi_arready;
  input [511:0]axi_rdata;
  input axi_rlast;
  input axi_rvalid;
  output axi_rready;
  input wr_addr_set;
  input [32:0]wr_addr;
  input rd_addr_set;
  input [32:0]rd_addr;
endmodule
