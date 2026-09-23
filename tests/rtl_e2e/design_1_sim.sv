// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
// -------------------------------------------------------------------------------

`timescale 1ns/1ps

(* BLOCK_STUB = "true" *)
module design_1 (
  M_AXI_GPIO_awaddr,
  M_AXI_GPIO_awlen,
  M_AXI_GPIO_awsize,
  M_AXI_GPIO_awburst,
  M_AXI_GPIO_awlock,
  M_AXI_GPIO_awcache,
  M_AXI_GPIO_awprot,
  M_AXI_GPIO_awqos,
  M_AXI_GPIO_awuser,
  M_AXI_GPIO_awvalid,
  M_AXI_GPIO_awready,
  M_AXI_GPIO_wdata,
  M_AXI_GPIO_wstrb,
  M_AXI_GPIO_wlast,
  M_AXI_GPIO_wvalid,
  M_AXI_GPIO_wready,
  M_AXI_GPIO_bresp,
  M_AXI_GPIO_bvalid,
  M_AXI_GPIO_bready,
  M_AXI_GPIO_araddr,
  M_AXI_GPIO_arlen,
  M_AXI_GPIO_arsize,
  M_AXI_GPIO_arburst,
  M_AXI_GPIO_arlock,
  M_AXI_GPIO_arcache,
  M_AXI_GPIO_arprot,
  M_AXI_GPIO_arqos,
  M_AXI_GPIO_aruser,
  M_AXI_GPIO_arvalid,
  M_AXI_GPIO_arready,
  M_AXI_GPIO_rdata,
  M_AXI_GPIO_rresp,
  M_AXI_GPIO_rlast,
  M_AXI_GPIO_rvalid,
  M_AXI_GPIO_rready,
  M_AXI_RFDC_awaddr,
  M_AXI_RFDC_awprot,
  M_AXI_RFDC_awvalid,
  M_AXI_RFDC_awready,
  M_AXI_RFDC_wdata,
  M_AXI_RFDC_wstrb,
  M_AXI_RFDC_wvalid,
  M_AXI_RFDC_wready,
  M_AXI_RFDC_bresp,
  M_AXI_RFDC_bvalid,
  M_AXI_RFDC_bready,
  M_AXI_RFDC_araddr,
  M_AXI_RFDC_arprot,
  M_AXI_RFDC_arvalid,
  M_AXI_RFDC_arready,
  M_AXI_RFDC_rdata,
  M_AXI_RFDC_rresp,
  M_AXI_RFDC_rvalid,
  M_AXI_RFDC_rready,
  M_AXI_PS_DDR_awid,
  M_AXI_PS_DDR_awaddr,
  M_AXI_PS_DDR_awlen,
  M_AXI_PS_DDR_awsize,
  M_AXI_PS_DDR_awburst,
  M_AXI_PS_DDR_awlock,
  M_AXI_PS_DDR_awcache,
  M_AXI_PS_DDR_awprot,
  M_AXI_PS_DDR_awvalid,
  M_AXI_PS_DDR_awuser,
  M_AXI_PS_DDR_awready,
  M_AXI_PS_DDR_wdata,
  M_AXI_PS_DDR_wstrb,
  M_AXI_PS_DDR_wlast,
  M_AXI_PS_DDR_wvalid,
  M_AXI_PS_DDR_wready,
  M_AXI_PS_DDR_bid,
  M_AXI_PS_DDR_bresp,
  M_AXI_PS_DDR_bvalid,
  M_AXI_PS_DDR_bready,
  M_AXI_PS_DDR_arid,
  M_AXI_PS_DDR_araddr,
  M_AXI_PS_DDR_arlen,
  M_AXI_PS_DDR_arsize,
  M_AXI_PS_DDR_arburst,
  M_AXI_PS_DDR_arlock,
  M_AXI_PS_DDR_arcache,
  M_AXI_PS_DDR_arprot,
  M_AXI_PS_DDR_arvalid,
  M_AXI_PS_DDR_aruser,
  M_AXI_PS_DDR_arready,
  M_AXI_PS_DDR_rid,
  M_AXI_PS_DDR_rdata,
  M_AXI_PS_DDR_rresp,
  M_AXI_PS_DDR_rlast,
  M_AXI_PS_DDR_rvalid,
  M_AXI_PS_DDR_rready,
  M_AXI_PS_DDR_awqos,
  M_AXI_PS_DDR_arqos,
  M_AXI_DMA_awaddr,
  M_AXI_DMA_awprot,
  M_AXI_DMA_awvalid,
  M_AXI_DMA_awready,
  M_AXI_DMA_wdata,
  M_AXI_DMA_wstrb,
  M_AXI_DMA_wvalid,
  M_AXI_DMA_wready,
  M_AXI_DMA_bresp,
  M_AXI_DMA_bvalid,
  M_AXI_DMA_bready,
  M_AXI_DMA_araddr,
  M_AXI_DMA_arprot,
  M_AXI_DMA_arvalid,
  M_AXI_DMA_arready,
  M_AXI_DMA_rdata,
  M_AXI_DMA_rresp,
  M_AXI_DMA_rvalid,
  M_AXI_DMA_rready,
  M_AXI_INST_awaddr,
  M_AXI_INST_awlen,
  M_AXI_INST_awsize,
  M_AXI_INST_awburst,
  M_AXI_INST_awlock,
  M_AXI_INST_awcache,
  M_AXI_INST_awprot,
  M_AXI_INST_awqos,
  M_AXI_INST_awuser,
  M_AXI_INST_awvalid,
  M_AXI_INST_awready,
  M_AXI_INST_wdata,
  M_AXI_INST_wstrb,
  M_AXI_INST_wlast,
  M_AXI_INST_wvalid,
  M_AXI_INST_wready,
  M_AXI_INST_bresp,
  M_AXI_INST_bvalid,
  M_AXI_INST_bready,
  M_AXI_INST_araddr,
  M_AXI_INST_arlen,
  M_AXI_INST_arsize,
  M_AXI_INST_arburst,
  M_AXI_INST_arlock,
  M_AXI_INST_arcache,
  M_AXI_INST_arprot,
  M_AXI_INST_arqos,
  M_AXI_INST_aruser,
  M_AXI_INST_arvalid,
  M_AXI_INST_arready,
  M_AXI_INST_rdata,
  M_AXI_INST_rresp,
  M_AXI_INST_rlast,
  M_AXI_INST_rvalid,
  M_AXI_INST_rready,
  pl_clk,
  pl_aresetn,
  ddr4_ui_clk,
  pl_resetn0,
  pl_ps_irq
);

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO AWADDR" *)
  (* X_INTERFACE_MODE = "master M_AXI_GPIO" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI_GPIO, DATA_WIDTH 32, PROTOCOL AXI4, FREQ_HZ 99999001, ID_WIDTH 0, ADDR_WIDTH 32, AWUSER_WIDTH 16, ARUSER_WIDTH 16, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 8, NUM_WRITE_OUTSTANDING 8, MAX_BURST_LENGTH 256, PHASE 0.0, CLK_DOMAIN design_1_zynq_ultra_ps_e_0_0_pl_clk0, NUM_READ_THREADS 1, NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0" *)
  output [31:0]M_AXI_GPIO_awaddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO AWLEN" *)
  output [7:0]M_AXI_GPIO_awlen;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO AWSIZE" *)
  output [2:0]M_AXI_GPIO_awsize;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO AWBURST" *)
  output [1:0]M_AXI_GPIO_awburst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO AWLOCK" *)
  output [0:0]M_AXI_GPIO_awlock;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO AWCACHE" *)
  output [3:0]M_AXI_GPIO_awcache;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO AWPROT" *)
  output [2:0]M_AXI_GPIO_awprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO AWQOS" *)
  output [3:0]M_AXI_GPIO_awqos;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO AWUSER" *)
  output [15:0]M_AXI_GPIO_awuser;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO AWVALID" *)
  output M_AXI_GPIO_awvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO AWREADY" *)
  input M_AXI_GPIO_awready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO WDATA" *)
  output [31:0]M_AXI_GPIO_wdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO WSTRB" *)
  output [3:0]M_AXI_GPIO_wstrb;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO WLAST" *)
  output M_AXI_GPIO_wlast;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO WVALID" *)
  output M_AXI_GPIO_wvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO WREADY" *)
  input M_AXI_GPIO_wready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO BRESP" *)
  input [1:0]M_AXI_GPIO_bresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO BVALID" *)
  input M_AXI_GPIO_bvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO BREADY" *)
  output M_AXI_GPIO_bready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO ARADDR" *)
  output [31:0]M_AXI_GPIO_araddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO ARLEN" *)
  output [7:0]M_AXI_GPIO_arlen;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO ARSIZE" *)
  output [2:0]M_AXI_GPIO_arsize;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO ARBURST" *)
  output [1:0]M_AXI_GPIO_arburst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO ARLOCK" *)
  output [0:0]M_AXI_GPIO_arlock;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO ARCACHE" *)
  output [3:0]M_AXI_GPIO_arcache;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO ARPROT" *)
  output [2:0]M_AXI_GPIO_arprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO ARQOS" *)
  output [3:0]M_AXI_GPIO_arqos;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO ARUSER" *)
  output [15:0]M_AXI_GPIO_aruser;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO ARVALID" *)
  output M_AXI_GPIO_arvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO ARREADY" *)
  input M_AXI_GPIO_arready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO RDATA" *)
  input [31:0]M_AXI_GPIO_rdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO RRESP" *)
  input [1:0]M_AXI_GPIO_rresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO RLAST" *)
  input M_AXI_GPIO_rlast;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO RVALID" *)
  input M_AXI_GPIO_rvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_GPIO RREADY" *)
  output M_AXI_GPIO_rready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_RFDC AWADDR" *)
  (* X_INTERFACE_MODE = "master M_AXI_RFDC" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI_RFDC, DATA_WIDTH 32, PROTOCOL AXI4LITE, FREQ_HZ 99999001, ID_WIDTH 0, ADDR_WIDTH 32, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 8, NUM_WRITE_OUTSTANDING 8, MAX_BURST_LENGTH 1, PHASE 0.0, CLK_DOMAIN design_1_zynq_ultra_ps_e_0_0_pl_clk0, NUM_READ_THREADS 1, NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0" *)
  output [31:0]M_AXI_RFDC_awaddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_RFDC AWPROT" *)
  output [2:0]M_AXI_RFDC_awprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_RFDC AWVALID" *)
  output M_AXI_RFDC_awvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_RFDC AWREADY" *)
  input M_AXI_RFDC_awready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_RFDC WDATA" *)
  output [31:0]M_AXI_RFDC_wdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_RFDC WSTRB" *)
  output [3:0]M_AXI_RFDC_wstrb;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_RFDC WVALID" *)
  output M_AXI_RFDC_wvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_RFDC WREADY" *)
  input M_AXI_RFDC_wready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_RFDC BRESP" *)
  input [1:0]M_AXI_RFDC_bresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_RFDC BVALID" *)
  input M_AXI_RFDC_bvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_RFDC BREADY" *)
  output M_AXI_RFDC_bready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_RFDC ARADDR" *)
  output [31:0]M_AXI_RFDC_araddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_RFDC ARPROT" *)
  output [2:0]M_AXI_RFDC_arprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_RFDC ARVALID" *)
  output M_AXI_RFDC_arvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_RFDC ARREADY" *)
  input M_AXI_RFDC_arready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_RFDC RDATA" *)
  input [31:0]M_AXI_RFDC_rdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_RFDC RRESP" *)
  input [1:0]M_AXI_RFDC_rresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_RFDC RVALID" *)
  input M_AXI_RFDC_rvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_RFDC RREADY" *)
  output M_AXI_RFDC_rready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR AWID" *)
  (* X_INTERFACE_MODE = "master M_AXI_PS_DDR" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI_PS_DDR, DATA_WIDTH 128, PROTOCOL AXI4, FREQ_HZ 100000000, ID_WIDTH 16, ADDR_WIDTH 40, AWUSER_WIDTH 16, ARUSER_WIDTH 16, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 1, HAS_LOCK 1, HAS_PROT 1, HAS_CACHE 1, HAS_QOS 1, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 1, NUM_READ_OUTSTANDING 8, NUM_WRITE_OUTSTANDING 8, MAX_BURST_LENGTH 256, PHASE 0.0, CLK_DOMAIN design_1_ddr4_ui_clk, NUM_READ_THREADS 4, NUM_WRITE_THREADS 4, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0" *)
  output [15:0]M_AXI_PS_DDR_awid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR AWADDR" *)
  output [39:0]M_AXI_PS_DDR_awaddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR AWLEN" *)
  output [7:0]M_AXI_PS_DDR_awlen;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR AWSIZE" *)
  output [2:0]M_AXI_PS_DDR_awsize;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR AWBURST" *)
  output [1:0]M_AXI_PS_DDR_awburst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR AWLOCK" *)
  output M_AXI_PS_DDR_awlock;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR AWCACHE" *)
  output [3:0]M_AXI_PS_DDR_awcache;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR AWPROT" *)
  output [2:0]M_AXI_PS_DDR_awprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR AWVALID" *)
  output M_AXI_PS_DDR_awvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR AWUSER" *)
  output [15:0]M_AXI_PS_DDR_awuser;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR AWREADY" *)
  input M_AXI_PS_DDR_awready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR WDATA" *)
  output [127:0]M_AXI_PS_DDR_wdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR WSTRB" *)
  output [15:0]M_AXI_PS_DDR_wstrb;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR WLAST" *)
  output M_AXI_PS_DDR_wlast;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR WVALID" *)
  output M_AXI_PS_DDR_wvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR WREADY" *)
  input M_AXI_PS_DDR_wready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR BID" *)
  input [15:0]M_AXI_PS_DDR_bid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR BRESP" *)
  input [1:0]M_AXI_PS_DDR_bresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR BVALID" *)
  input M_AXI_PS_DDR_bvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR BREADY" *)
  output M_AXI_PS_DDR_bready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR ARID" *)
  output [15:0]M_AXI_PS_DDR_arid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR ARADDR" *)
  output [39:0]M_AXI_PS_DDR_araddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR ARLEN" *)
  output [7:0]M_AXI_PS_DDR_arlen;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR ARSIZE" *)
  output [2:0]M_AXI_PS_DDR_arsize;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR ARBURST" *)
  output [1:0]M_AXI_PS_DDR_arburst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR ARLOCK" *)
  output M_AXI_PS_DDR_arlock;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR ARCACHE" *)
  output [3:0]M_AXI_PS_DDR_arcache;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR ARPROT" *)
  output [2:0]M_AXI_PS_DDR_arprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR ARVALID" *)
  output M_AXI_PS_DDR_arvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR ARUSER" *)
  output [15:0]M_AXI_PS_DDR_aruser;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR ARREADY" *)
  input M_AXI_PS_DDR_arready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR RID" *)
  input [15:0]M_AXI_PS_DDR_rid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR RDATA" *)
  input [127:0]M_AXI_PS_DDR_rdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR RRESP" *)
  input [1:0]M_AXI_PS_DDR_rresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR RLAST" *)
  input M_AXI_PS_DDR_rlast;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR RVALID" *)
  input M_AXI_PS_DDR_rvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR RREADY" *)
  output M_AXI_PS_DDR_rready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR AWQOS" *)
  output [3:0]M_AXI_PS_DDR_awqos;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_PS_DDR ARQOS" *)
  output [3:0]M_AXI_PS_DDR_arqos;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DMA AWADDR" *)
  (* X_INTERFACE_MODE = "master M_AXI_DMA" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI_DMA, DATA_WIDTH 32, PROTOCOL AXI4LITE, FREQ_HZ 99999001, ID_WIDTH 0, ADDR_WIDTH 32, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 1, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 8, NUM_WRITE_OUTSTANDING 8, MAX_BURST_LENGTH 1, PHASE 0.0, CLK_DOMAIN design_1_zynq_ultra_ps_e_0_0_pl_clk0, NUM_READ_THREADS 1, NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0" *)
  output [31:0]M_AXI_DMA_awaddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DMA AWPROT" *)
  output [2:0]M_AXI_DMA_awprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DMA AWVALID" *)
  output M_AXI_DMA_awvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DMA AWREADY" *)
  input M_AXI_DMA_awready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DMA WDATA" *)
  output [31:0]M_AXI_DMA_wdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DMA WSTRB" *)
  output [3:0]M_AXI_DMA_wstrb;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DMA WVALID" *)
  output M_AXI_DMA_wvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DMA WREADY" *)
  input M_AXI_DMA_wready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DMA BRESP" *)
  input [1:0]M_AXI_DMA_bresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DMA BVALID" *)
  input M_AXI_DMA_bvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DMA BREADY" *)
  output M_AXI_DMA_bready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DMA ARADDR" *)
  output [31:0]M_AXI_DMA_araddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DMA ARPROT" *)
  output [2:0]M_AXI_DMA_arprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DMA ARVALID" *)
  output M_AXI_DMA_arvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DMA ARREADY" *)
  input M_AXI_DMA_arready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DMA RDATA" *)
  input [31:0]M_AXI_DMA_rdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DMA RRESP" *)
  input [1:0]M_AXI_DMA_rresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DMA RVALID" *)
  input M_AXI_DMA_rvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DMA RREADY" *)
  output M_AXI_DMA_rready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST AWADDR" *)
  (* X_INTERFACE_MODE = "master M_AXI_INST" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI_INST, DATA_WIDTH 32, PROTOCOL AXI4, FREQ_HZ 99999001, ID_WIDTH 0, ADDR_WIDTH 32, AWUSER_WIDTH 16, ARUSER_WIDTH 16, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 1, HAS_LOCK 1, HAS_PROT 1, HAS_CACHE 1, HAS_QOS 1, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 8, NUM_WRITE_OUTSTANDING 8, MAX_BURST_LENGTH 256, PHASE 0.0, CLK_DOMAIN design_1_zynq_ultra_ps_e_0_0_pl_clk0, NUM_READ_THREADS 1, NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0" *)
  output [31:0]M_AXI_INST_awaddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST AWLEN" *)
  output [7:0]M_AXI_INST_awlen;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST AWSIZE" *)
  output [2:0]M_AXI_INST_awsize;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST AWBURST" *)
  output [1:0]M_AXI_INST_awburst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST AWLOCK" *)
  output [0:0]M_AXI_INST_awlock;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST AWCACHE" *)
  output [3:0]M_AXI_INST_awcache;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST AWPROT" *)
  output [2:0]M_AXI_INST_awprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST AWQOS" *)
  output [3:0]M_AXI_INST_awqos;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST AWUSER" *)
  output [15:0]M_AXI_INST_awuser;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST AWVALID" *)
  output M_AXI_INST_awvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST AWREADY" *)
  input M_AXI_INST_awready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST WDATA" *)
  output [31:0]M_AXI_INST_wdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST WSTRB" *)
  output [3:0]M_AXI_INST_wstrb;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST WLAST" *)
  output M_AXI_INST_wlast;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST WVALID" *)
  output M_AXI_INST_wvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST WREADY" *)
  input M_AXI_INST_wready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST BRESP" *)
  input [1:0]M_AXI_INST_bresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST BVALID" *)
  input M_AXI_INST_bvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST BREADY" *)
  output M_AXI_INST_bready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST ARADDR" *)
  output [31:0]M_AXI_INST_araddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST ARLEN" *)
  output [7:0]M_AXI_INST_arlen;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST ARSIZE" *)
  output [2:0]M_AXI_INST_arsize;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST ARBURST" *)
  output [1:0]M_AXI_INST_arburst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST ARLOCK" *)
  output [0:0]M_AXI_INST_arlock;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST ARCACHE" *)
  output [3:0]M_AXI_INST_arcache;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST ARPROT" *)
  output [2:0]M_AXI_INST_arprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST ARQOS" *)
  output [3:0]M_AXI_INST_arqos;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST ARUSER" *)
  output [15:0]M_AXI_INST_aruser;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST ARVALID" *)
  output M_AXI_INST_arvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST ARREADY" *)
  input M_AXI_INST_arready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST RDATA" *)
  input [31:0]M_AXI_INST_rdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST RRESP" *)
  input [1:0]M_AXI_INST_rresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST RLAST" *)
  input M_AXI_INST_rlast;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST RVALID" *)
  input M_AXI_INST_rvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_INST RREADY" *)
  output M_AXI_INST_rready;
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK.PL_CLK CLK" *)
  (* X_INTERFACE_MODE = "master CLK.PL_CLK" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.PL_CLK, FREQ_HZ 99999001, FREQ_TOLERANCE_HZ 0, PHASE 0.0, CLK_DOMAIN design_1_zynq_ultra_ps_e_0_0_pl_clk0, ASSOCIATED_BUSIF M_AXI_GPIO:M_AXI_DMA:M_AXI_INST:M_AXI_RFDC, ASSOCIATED_RESET pl_aresetn, INSERT_VIP 0" *)
  output pl_clk;
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 RST.PL_ARESETN RST" *)
  (* X_INTERFACE_MODE = "slave RST.PL_ARESETN" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME RST.PL_ARESETN, POLARITY ACTIVE_LOW, INSERT_VIP 0" *)
  input [0:0]pl_aresetn;
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK.DDR4_UI_CLK CLK" *)
  (* X_INTERFACE_MODE = "slave CLK.DDR4_UI_CLK" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.DDR4_UI_CLK, FREQ_HZ 100000000, FREQ_TOLERANCE_HZ 0, PHASE 0.0, CLK_DOMAIN design_1_ddr4_ui_clk, ASSOCIATED_BUSIF M_AXI_PS_DDR, ASSOCIATED_RESET ddr4_ui_aresetn, INSERT_VIP 0" *)
  input ddr4_ui_clk;
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 RST.PL_RESETN0 RST" *)
  (* X_INTERFACE_MODE = "master RST.PL_RESETN0" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME RST.PL_RESETN0, POLARITY ACTIVE_LOW, INSERT_VIP 0" *)
  output [0:0]pl_resetn0;
  (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 INTR.PL_PS_IRQ INTERRUPT" *)
  (* X_INTERFACE_MODE = "slave INTR.PL_PS_IRQ" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME INTR.PL_PS_IRQ, SENSITIVITY EDGE_RISING, PortWidth 1" *)
  input [0:0]pl_ps_irq;

  // stub module has no contents


  reg sim_pl_clk = 1'b0;
  always #5 sim_pl_clk = ~sim_pl_clk;
  reg [1:0] sim_reset_count = 2'b00;
  always @(posedge sim_pl_clk) begin
    if (sim_reset_count != 2'b11) sim_reset_count <= sim_reset_count + 1'b1;
  end
  assign pl_clk = sim_pl_clk;
  assign pl_resetn0 = (sim_reset_count == 2'b11);
  // -------------------------------------------------------------------
  // PS firmware model.
  //
  // The production firmware publishes the DAC MTS status word to the PL over
  // the AXI GPIO2 register.  Bit 1 reports that MTS is required, bit 2 that
  // MTS completed and bit 24 that the firmware NCO/SYSREF synchronisation is
  // ready.  Everything else in the word stays clear.
  //
  // The write is issued over the real AXI4-Lite master port so the design's
  // own GPIO register and its PL/DDR-domain synchronisers are exercised.
  // -------------------------------------------------------------------
  localparam [31:0] GPIO2_FIRMWARE_STATUS = 32'h0100_0006;
  reg [2:0]  gpio_fsm;
  reg [31:0] gpio_awaddr_q;
  reg [31:0] gpio_wdata_q;
  reg        gpio_awvalid_q;
  reg        gpio_wvalid_q;
  reg        gpio_bready_q;

  assign M_AXI_GPIO_awaddr  = gpio_awaddr_q;
  assign M_AXI_GPIO_awlen   = 8'd0;
  assign M_AXI_GPIO_awsize  = 3'd2;
  assign M_AXI_GPIO_awburst = 2'b01;
  assign M_AXI_GPIO_awlock  = 1'b0;
  assign M_AXI_GPIO_awcache = 4'b0000;
  assign M_AXI_GPIO_awprot  = 3'b000;
  assign M_AXI_GPIO_awqos   = 4'd0;
  assign M_AXI_GPIO_awuser  = 16'd0;
  assign M_AXI_GPIO_awvalid = gpio_awvalid_q;
  assign M_AXI_GPIO_wdata   = gpio_wdata_q;
  assign M_AXI_GPIO_wstrb   = 4'hF;
  assign M_AXI_GPIO_wlast   = 1'b1;
  assign M_AXI_GPIO_wvalid  = gpio_wvalid_q;
  assign M_AXI_GPIO_bready  = gpio_bready_q;
  assign M_AXI_GPIO_araddr  = 32'd0;
  assign M_AXI_GPIO_arlen   = 8'd0;
  assign M_AXI_GPIO_arsize  = 3'd2;
  assign M_AXI_GPIO_arburst = 2'b01;
  assign M_AXI_GPIO_arlock  = 1'b0;
  assign M_AXI_GPIO_arcache = 4'b0000;
  assign M_AXI_GPIO_arprot  = 3'b000;
  assign M_AXI_GPIO_arqos   = 4'd0;
  assign M_AXI_GPIO_aruser  = 16'd0;
  assign M_AXI_GPIO_arvalid = 1'b0;
  assign M_AXI_GPIO_rready  = 1'b0;

  always @(posedge sim_pl_clk) begin
    if (!pl_aresetn) begin
      gpio_fsm      <= 3'd0;
      gpio_awaddr_q <= 32'd0;
      gpio_wdata_q  <= 32'd0;
      gpio_awvalid_q <= 1'b0;
      gpio_wvalid_q  <= 1'b0;
      gpio_bready_q  <= 1'b0;
    end else begin
      case (gpio_fsm)
        3'd0: begin
          gpio_awaddr_q  <= 32'h008;
          gpio_wdata_q   <= GPIO2_FIRMWARE_STATUS;
          gpio_awvalid_q <= 1'b1;
          gpio_wvalid_q  <= 1'b1;
          gpio_bready_q  <= 1'b1;
          gpio_fsm       <= 3'd1;
        end
        3'd1: begin
          if (M_AXI_GPIO_awready) gpio_awvalid_q <= 1'b0;
          if (M_AXI_GPIO_wready)  gpio_wvalid_q  <= 1'b0;
          if ((!gpio_awvalid_q || M_AXI_GPIO_awready) &&
              (!gpio_wvalid_q  || M_AXI_GPIO_wready))
            gpio_fsm <= 3'd2;
        end
        3'd2: if (M_AXI_GPIO_bvalid) gpio_fsm <= 3'd3;
        3'd3: begin
          gpio_bready_q <= 1'b0;
          gpio_fsm      <= 3'd4;
        end
        default: gpio_fsm <= gpio_fsm;
      endcase
    end
  end
  assign M_AXI_RFDC_awvalid = 0;
  assign M_AXI_RFDC_wvalid = 0;
  assign M_AXI_RFDC_bready = 0;
  assign M_AXI_RFDC_arvalid = 0;
  assign M_AXI_RFDC_rready = 0;
  assign M_AXI_PS_DDR_awlock = 0;
  assign M_AXI_PS_DDR_awvalid = 0;
  assign M_AXI_PS_DDR_wlast = 0;
  assign M_AXI_PS_DDR_wvalid = 0;
  assign M_AXI_PS_DDR_bready = 0;
  assign M_AXI_PS_DDR_arlock = 0;
  assign M_AXI_PS_DDR_arvalid = 0;
  assign M_AXI_PS_DDR_rready = 0;
  assign M_AXI_DMA_awvalid = 0;
  assign M_AXI_DMA_wvalid = 0;
  assign M_AXI_DMA_bready = 0;
  assign M_AXI_DMA_arvalid = 0;
  assign M_AXI_DMA_rready = 0;
  assign M_AXI_INST_awvalid = 0;
  assign M_AXI_INST_wlast = 0;
  assign M_AXI_INST_wvalid = 0;
  assign M_AXI_INST_bready = 0;
  assign M_AXI_INST_arvalid = 0;
  assign M_AXI_INST_rready = 0;

endmodule
