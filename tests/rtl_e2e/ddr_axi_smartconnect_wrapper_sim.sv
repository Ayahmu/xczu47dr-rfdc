// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
// -------------------------------------------------------------------------------

`timescale 1 ps / 1 ps

(* BLOCK_STUB = "true" *)
module ddr_axi_smartconnect_wrapper (
  S_AXI_PS_awid,
  S_AXI_PS_awaddr,
  S_AXI_PS_awlen,
  S_AXI_PS_awsize,
  S_AXI_PS_awburst,
  S_AXI_PS_awlock,
  S_AXI_PS_awcache,
  S_AXI_PS_awprot,
  S_AXI_PS_awqos,
  S_AXI_PS_awuser,
  S_AXI_PS_awvalid,
  S_AXI_PS_awready,
  S_AXI_PS_wdata,
  S_AXI_PS_wstrb,
  S_AXI_PS_wlast,
  S_AXI_PS_wvalid,
  S_AXI_PS_wready,
  S_AXI_PS_bid,
  S_AXI_PS_bresp,
  S_AXI_PS_bvalid,
  S_AXI_PS_bready,
  S_AXI_PS_arid,
  S_AXI_PS_araddr,
  S_AXI_PS_arlen,
  S_AXI_PS_arsize,
  S_AXI_PS_arburst,
  S_AXI_PS_arlock,
  S_AXI_PS_arcache,
  S_AXI_PS_arprot,
  S_AXI_PS_arqos,
  S_AXI_PS_aruser,
  S_AXI_PS_arvalid,
  S_AXI_PS_arready,
  S_AXI_PS_rid,
  S_AXI_PS_rdata,
  S_AXI_PS_rresp,
  S_AXI_PS_rlast,
  S_AXI_PS_rvalid,
  S_AXI_PS_rready,
  S_AXI_DM_araddr,
  S_AXI_DM_arlen,
  S_AXI_DM_arsize,
  S_AXI_DM_arburst,
  S_AXI_DM_arlock,
  S_AXI_DM_arcache,
  S_AXI_DM_arprot,
  S_AXI_DM_arqos,
  S_AXI_DM_arvalid,
  S_AXI_DM_arready,
  S_AXI_DM_rdata,
  S_AXI_DM_rresp,
  S_AXI_DM_rlast,
  S_AXI_DM_rvalid,
  S_AXI_DM_rready,
  S_AXI_WAVE_awaddr,
  S_AXI_WAVE_awlen,
  S_AXI_WAVE_awsize,
  S_AXI_WAVE_awburst,
  S_AXI_WAVE_awlock,
  S_AXI_WAVE_awcache,
  S_AXI_WAVE_awprot,
  S_AXI_WAVE_awqos,
  S_AXI_WAVE_awvalid,
  S_AXI_WAVE_awready,
  S_AXI_WAVE_wdata,
  S_AXI_WAVE_wstrb,
  S_AXI_WAVE_wlast,
  S_AXI_WAVE_wvalid,
  S_AXI_WAVE_wready,
  S_AXI_WAVE_bresp,
  S_AXI_WAVE_bvalid,
  S_AXI_WAVE_bready,
  M_AXI_DDR_awaddr,
  M_AXI_DDR_awlen,
  M_AXI_DDR_awsize,
  M_AXI_DDR_awburst,
  M_AXI_DDR_awlock,
  M_AXI_DDR_awcache,
  M_AXI_DDR_awprot,
  M_AXI_DDR_awqos,
  M_AXI_DDR_awuser,
  M_AXI_DDR_awvalid,
  M_AXI_DDR_awready,
  M_AXI_DDR_wdata,
  M_AXI_DDR_wstrb,
  M_AXI_DDR_wlast,
  M_AXI_DDR_wvalid,
  M_AXI_DDR_wready,
  M_AXI_DDR_bresp,
  M_AXI_DDR_bvalid,
  M_AXI_DDR_bready,
  M_AXI_DDR_araddr,
  M_AXI_DDR_arlen,
  M_AXI_DDR_arsize,
  M_AXI_DDR_arburst,
  M_AXI_DDR_arlock,
  M_AXI_DDR_arcache,
  M_AXI_DDR_arprot,
  M_AXI_DDR_arqos,
  M_AXI_DDR_aruser,
  M_AXI_DDR_arvalid,
  M_AXI_DDR_arready,
  M_AXI_DDR_rdata,
  M_AXI_DDR_rresp,
  M_AXI_DDR_rlast,
  M_AXI_DDR_rvalid,
  M_AXI_DDR_rready,
  aclk,
  aresetn
);

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS AWID" *)
  (* X_INTERFACE_MODE = "slave S_AXI_PS" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI_PS, DATA_WIDTH 128, PROTOCOL AXI4, FREQ_HZ 100000000, ID_WIDTH 16, ADDR_WIDTH 40, AWUSER_WIDTH 16, ARUSER_WIDTH 16, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 1, HAS_LOCK 1, HAS_PROT 1, HAS_CACHE 1, HAS_QOS 1, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 1, NUM_READ_OUTSTANDING 8, NUM_WRITE_OUTSTANDING 8, MAX_BURST_LENGTH 256, PHASE 0.0, CLK_DOMAIN ddr_axi_smartconnect_aclk, NUM_READ_THREADS 1, NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0" *)
  input [15:0]S_AXI_PS_awid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS AWADDR" *)
  input [39:0]S_AXI_PS_awaddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS AWLEN" *)
  input [7:0]S_AXI_PS_awlen;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS AWSIZE" *)
  input [2:0]S_AXI_PS_awsize;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS AWBURST" *)
  input [1:0]S_AXI_PS_awburst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS AWLOCK" *)
  input [0:0]S_AXI_PS_awlock;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS AWCACHE" *)
  input [3:0]S_AXI_PS_awcache;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS AWPROT" *)
  input [2:0]S_AXI_PS_awprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS AWQOS" *)
  input [3:0]S_AXI_PS_awqos;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS AWUSER" *)
  input [15:0]S_AXI_PS_awuser;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS AWVALID" *)
  input S_AXI_PS_awvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS AWREADY" *)
  output S_AXI_PS_awready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS WDATA" *)
  input [127:0]S_AXI_PS_wdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS WSTRB" *)
  input [15:0]S_AXI_PS_wstrb;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS WLAST" *)
  input S_AXI_PS_wlast;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS WVALID" *)
  input S_AXI_PS_wvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS WREADY" *)
  output S_AXI_PS_wready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS BID" *)
  output [15:0]S_AXI_PS_bid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS BRESP" *)
  output [1:0]S_AXI_PS_bresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS BVALID" *)
  output S_AXI_PS_bvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS BREADY" *)
  input S_AXI_PS_bready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS ARID" *)
  input [15:0]S_AXI_PS_arid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS ARADDR" *)
  input [39:0]S_AXI_PS_araddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS ARLEN" *)
  input [7:0]S_AXI_PS_arlen;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS ARSIZE" *)
  input [2:0]S_AXI_PS_arsize;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS ARBURST" *)
  input [1:0]S_AXI_PS_arburst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS ARLOCK" *)
  input [0:0]S_AXI_PS_arlock;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS ARCACHE" *)
  input [3:0]S_AXI_PS_arcache;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS ARPROT" *)
  input [2:0]S_AXI_PS_arprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS ARQOS" *)
  input [3:0]S_AXI_PS_arqos;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS ARUSER" *)
  input [15:0]S_AXI_PS_aruser;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS ARVALID" *)
  input S_AXI_PS_arvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS ARREADY" *)
  output S_AXI_PS_arready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS RID" *)
  output [15:0]S_AXI_PS_rid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS RDATA" *)
  output [127:0]S_AXI_PS_rdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS RRESP" *)
  output [1:0]S_AXI_PS_rresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS RLAST" *)
  output S_AXI_PS_rlast;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS RVALID" *)
  output S_AXI_PS_rvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_PS RREADY" *)
  input S_AXI_PS_rready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_DM ARADDR" *)
  (* X_INTERFACE_MODE = "slave S_AXI_DM" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI_DM, DATA_WIDTH 512, PROTOCOL AXI4, FREQ_HZ 100000000, ID_WIDTH 0, ADDR_WIDTH 64, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_ONLY, HAS_BURST 1, HAS_LOCK 1, HAS_PROT 1, HAS_CACHE 1, HAS_QOS 1, HAS_REGION 1, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 1, NUM_READ_OUTSTANDING 16, NUM_WRITE_OUTSTANDING 2, MAX_BURST_LENGTH 64, PHASE 0.0, CLK_DOMAIN ddr_axi_smartconnect_aclk, NUM_READ_THREADS 1, NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0" *)
  input [63:0]S_AXI_DM_araddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_DM ARLEN" *)
  input [7:0]S_AXI_DM_arlen;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_DM ARSIZE" *)
  input [2:0]S_AXI_DM_arsize;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_DM ARBURST" *)
  input [1:0]S_AXI_DM_arburst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_DM ARLOCK" *)
  input [0:0]S_AXI_DM_arlock;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_DM ARCACHE" *)
  input [3:0]S_AXI_DM_arcache;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_DM ARPROT" *)
  input [2:0]S_AXI_DM_arprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_DM ARQOS" *)
  input [3:0]S_AXI_DM_arqos;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_DM ARVALID" *)
  input S_AXI_DM_arvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_DM ARREADY" *)
  output S_AXI_DM_arready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_DM RDATA" *)
  output [511:0]S_AXI_DM_rdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_DM RRESP" *)
  output [1:0]S_AXI_DM_rresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_DM RLAST" *)
  output S_AXI_DM_rlast;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_DM RVALID" *)
  output S_AXI_DM_rvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_DM RREADY" *)
  input S_AXI_DM_rready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_WAVE AWADDR" *)
  (* X_INTERFACE_MODE = "slave S_AXI_WAVE" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI_WAVE, DATA_WIDTH 256, PROTOCOL AXI4, FREQ_HZ 100000000, ID_WIDTH 0, ADDR_WIDTH 64, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE WRITE_ONLY, HAS_BURST 1, HAS_LOCK 1, HAS_PROT 1, HAS_CACHE 1, HAS_QOS 1, HAS_REGION 1, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 1, NUM_READ_OUTSTANDING 2, NUM_WRITE_OUTSTANDING 8, MAX_BURST_LENGTH 16, PHASE 0.0, CLK_DOMAIN ddr_axi_smartconnect_aclk, NUM_READ_THREADS 1, NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0" *)
  input [63:0]S_AXI_WAVE_awaddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_WAVE AWLEN" *)
  input [7:0]S_AXI_WAVE_awlen;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_WAVE AWSIZE" *)
  input [2:0]S_AXI_WAVE_awsize;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_WAVE AWBURST" *)
  input [1:0]S_AXI_WAVE_awburst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_WAVE AWLOCK" *)
  input [0:0]S_AXI_WAVE_awlock;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_WAVE AWCACHE" *)
  input [3:0]S_AXI_WAVE_awcache;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_WAVE AWPROT" *)
  input [2:0]S_AXI_WAVE_awprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_WAVE AWQOS" *)
  input [3:0]S_AXI_WAVE_awqos;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_WAVE AWVALID" *)
  input S_AXI_WAVE_awvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_WAVE AWREADY" *)
  output S_AXI_WAVE_awready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_WAVE WDATA" *)
  input [255:0]S_AXI_WAVE_wdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_WAVE WSTRB" *)
  input [31:0]S_AXI_WAVE_wstrb;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_WAVE WLAST" *)
  input S_AXI_WAVE_wlast;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_WAVE WVALID" *)
  input S_AXI_WAVE_wvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_WAVE WREADY" *)
  output S_AXI_WAVE_wready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_WAVE BRESP" *)
  output [1:0]S_AXI_WAVE_bresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_WAVE BVALID" *)
  output S_AXI_WAVE_bvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_WAVE BREADY" *)
  input S_AXI_WAVE_bready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR AWADDR" *)
  (* X_INTERFACE_MODE = "master M_AXI_DDR" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI_DDR, DATA_WIDTH 512, PROTOCOL AXI4, FREQ_HZ 100000000, ID_WIDTH 0, ADDR_WIDTH 40, AWUSER_WIDTH 16, ARUSER_WIDTH 16, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 1, HAS_LOCK 1, HAS_PROT 1, HAS_CACHE 1, HAS_QOS 1, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 8, NUM_WRITE_OUTSTANDING 8, MAX_BURST_LENGTH 64, PHASE 0.0, CLK_DOMAIN ddr_axi_smartconnect_aclk, NUM_READ_THREADS 1, NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0" *)
  output [39:0]M_AXI_DDR_awaddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR AWLEN" *)
  output [7:0]M_AXI_DDR_awlen;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR AWSIZE" *)
  output [2:0]M_AXI_DDR_awsize;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR AWBURST" *)
  output [1:0]M_AXI_DDR_awburst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR AWLOCK" *)
  output [0:0]M_AXI_DDR_awlock;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR AWCACHE" *)
  output [3:0]M_AXI_DDR_awcache;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR AWPROT" *)
  output [2:0]M_AXI_DDR_awprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR AWQOS" *)
  output [3:0]M_AXI_DDR_awqos;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR AWUSER" *)
  output [15:0]M_AXI_DDR_awuser;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR AWVALID" *)
  output M_AXI_DDR_awvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR AWREADY" *)
  input M_AXI_DDR_awready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR WDATA" *)
  output [511:0]M_AXI_DDR_wdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR WSTRB" *)
  output [63:0]M_AXI_DDR_wstrb;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR WLAST" *)
  output M_AXI_DDR_wlast;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR WVALID" *)
  output M_AXI_DDR_wvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR WREADY" *)
  input M_AXI_DDR_wready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR BRESP" *)
  input [1:0]M_AXI_DDR_bresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR BVALID" *)
  input M_AXI_DDR_bvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR BREADY" *)
  output M_AXI_DDR_bready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR ARADDR" *)
  output [39:0]M_AXI_DDR_araddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR ARLEN" *)
  output [7:0]M_AXI_DDR_arlen;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR ARSIZE" *)
  output [2:0]M_AXI_DDR_arsize;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR ARBURST" *)
  output [1:0]M_AXI_DDR_arburst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR ARLOCK" *)
  output [0:0]M_AXI_DDR_arlock;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR ARCACHE" *)
  output [3:0]M_AXI_DDR_arcache;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR ARPROT" *)
  output [2:0]M_AXI_DDR_arprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR ARQOS" *)
  output [3:0]M_AXI_DDR_arqos;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR ARUSER" *)
  output [15:0]M_AXI_DDR_aruser;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR ARVALID" *)
  output M_AXI_DDR_arvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR ARREADY" *)
  input M_AXI_DDR_arready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR RDATA" *)
  input [511:0]M_AXI_DDR_rdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR RRESP" *)
  input [1:0]M_AXI_DDR_rresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR RLAST" *)
  input M_AXI_DDR_rlast;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR RVALID" *)
  input M_AXI_DDR_rvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_DDR RREADY" *)
  output M_AXI_DDR_rready;
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK.ACLK CLK" *)
  (* X_INTERFACE_MODE = "slave CLK.ACLK" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.ACLK, FREQ_HZ 100000000, FREQ_TOLERANCE_HZ 0, PHASE 0.0, CLK_DOMAIN ddr_axi_smartconnect_aclk, ASSOCIATED_BUSIF S_AXI_PS:S_AXI_DM:S_AXI_WAVE:M_AXI_DDR, ASSOCIATED_RESET aresetn, INSERT_VIP 0" *)
  input aclk;
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 RST.ARESETN RST" *)
  (* X_INTERFACE_MODE = "slave RST.ARESETN" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME RST.ARESETN, POLARITY ACTIVE_LOW, INSERT_VIP 0" *)
  input [0:0]aresetn;

  // stub module has no contents


  // 256-bit word memory indexed by 32-byte address.  The writer emits one
  // 32-byte AXI write per address; the reader consumes paired words as a
  // 512-bit DDR beat (64 bytes).
  reg [255:0] mem [0:255];
  reg        wave_aw_pending;
  reg [63:0] wave_awaddr_q;
  reg [7:0]  wave_awlen_q;
  reg        wave_w_pending;
  reg [255:0] wave_wdata_q;
  reg [31:0] wave_wstrb_q;
  reg        wave_bvalid_q;

  reg        dm_active;
  reg [63:0] dm_addr_q;
  reg [7:0]  dm_len_q;
  reg [7:0]  dm_count_q;
  reg [511:0] dm_rdata_q;
  reg          dm_rvalid_q;

  wire wave_aw_fire = S_AXI_WAVE_awvalid && S_AXI_WAVE_awready;
  wire wave_w_fire  = S_AXI_WAVE_wvalid  && S_AXI_WAVE_wready;
  wire wave_store   = wave_aw_pending && wave_w_pending;
  // Production places the waveform window at 0x4800_0000.  This model keeps a
  // small image of that window, so both the write and the read port subtract
  // the window base instead of indexing the full AXI address space.
  localparam [63:0] WAVE_WINDOW_BASE = 64'h0000_0048_0000_0000;
  wire [63:0] wave_offset = wave_awaddr_q - WAVE_WINDOW_BASE;
  wire [63:0] dm_offset   = dm_addr_q   - WAVE_WINDOW_BASE;
  wire [31:0] wave_word_addr = wave_offset[31:0] >> 5;
  wire dm_ar_fire = S_AXI_DM_arvalid && S_AXI_DM_arready;
  wire dm_r_fire  = dm_rvalid_q && S_AXI_DM_rready;
  wire [31:0] dm_word_addr = dm_offset[31:0] >> 5;

  assign S_AXI_PS_awready = 1'b0;
  assign S_AXI_PS_wready  = 1'b0;
  assign S_AXI_PS_bvalid  = 1'b0;
  assign S_AXI_PS_bid     = 16'd0;
  assign S_AXI_PS_bresp   = 2'b00;
  assign S_AXI_PS_arready = 1'b0;
  assign S_AXI_PS_rvalid  = 1'b0;
  assign S_AXI_PS_rid     = 16'd0;
  assign S_AXI_PS_rdata   = 128'd0;
  assign S_AXI_PS_rresp   = 2'b00;
  assign S_AXI_PS_rlast   = 1'b0;

  assign S_AXI_WAVE_awready = !wave_aw_pending && !wave_bvalid_q;
  assign S_AXI_WAVE_wready  = !wave_w_pending && !wave_bvalid_q;
  assign S_AXI_WAVE_bvalid  = wave_bvalid_q;
  assign S_AXI_WAVE_bresp   = 2'b00;

  assign S_AXI_DM_arready = !dm_active && !dm_rvalid_q;
  assign S_AXI_DM_rvalid  = dm_rvalid_q;
  assign S_AXI_DM_rdata   = dm_rdata_q;
  assign S_AXI_DM_rresp   = 2'b00;
  assign S_AXI_DM_rlast   = dm_active && (dm_count_q == 8'd1);

  assign M_AXI_DDR_awaddr  = 40'd0;
  assign M_AXI_DDR_awlen   = 8'd0;
  assign M_AXI_DDR_awsize  = 3'd0;
  assign M_AXI_DDR_awburst = 2'd0;
  assign M_AXI_DDR_awlock  = 1'b0;
  assign M_AXI_DDR_awcache = 4'd0;
  assign M_AXI_DDR_awprot  = 3'd0;
  assign M_AXI_DDR_awqos   = 4'd0;
  assign M_AXI_DDR_awuser  = 16'd0;
  assign M_AXI_DDR_awvalid = 1'b0;
  assign M_AXI_DDR_wdata   = 512'd0;
  assign M_AXI_DDR_wstrb   = 64'd0;
  assign M_AXI_DDR_wlast   = 1'b0;
  assign M_AXI_DDR_wvalid  = 1'b0;
  assign M_AXI_DDR_bready  = 1'b0;
  assign M_AXI_DDR_araddr  = 40'd0;
  assign M_AXI_DDR_arlen   = 8'd0;
  assign M_AXI_DDR_arsize  = 3'd0;
  assign M_AXI_DDR_arburst = 2'd0;
  assign M_AXI_DDR_arlock  = 1'b0;
  assign M_AXI_DDR_arcache = 4'd0;
  assign M_AXI_DDR_arprot  = 3'd0;
  assign M_AXI_DDR_arqos   = 4'd0;
  assign M_AXI_DDR_aruser  = 16'd0;
  assign M_AXI_DDR_arvalid = 1'b0;
  assign M_AXI_DDR_rready  = 1'b0;

  integer i;
  initial begin
    wave_aw_pending = 0;
    wave_w_pending  = 0;
    wave_bvalid_q   = 0;
    dm_active       = 0;
    dm_rvalid_q     = 0;
    for (i = 0; i < 256; i = i + 1) mem[i] = 256'd0;
  end

  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      wave_aw_pending <= 1'b0;
      wave_w_pending  <= 1'b0;
      wave_bvalid_q   <= 1'b0;
      dm_active       <= 1'b0;
      dm_rvalid_q     <= 1'b0;
    end else begin
      if (wave_aw_fire) begin
        wave_awaddr_q <= S_AXI_WAVE_awaddr;
        wave_awlen_q  <= S_AXI_WAVE_awlen;
        wave_aw_pending <= 1'b1;
      end
      if (wave_w_fire) begin
        wave_wdata_q <= S_AXI_WAVE_wdata;
        wave_wstrb_q <= S_AXI_WAVE_wstrb;
        wave_w_pending <= 1'b1;
      end
      if (wave_store) begin
        if (wave_wstrb_q[0])  mem[wave_word_addr][7:0]   <= wave_wdata_q[7:0];
        if (wave_wstrb_q[1])  mem[wave_word_addr][15:8]  <= wave_wdata_q[15:8];
        if (wave_wstrb_q[2])  mem[wave_word_addr][23:16] <= wave_wdata_q[23:16];
        if (wave_wstrb_q[3])  mem[wave_word_addr][31:24] <= wave_wdata_q[31:24];
        if (wave_wstrb_q[4])  mem[wave_word_addr][39:32] <= wave_wdata_q[39:32];
        if (wave_wstrb_q[5])  mem[wave_word_addr][47:40] <= wave_wdata_q[47:40];
        if (wave_wstrb_q[6])  mem[wave_word_addr][55:48] <= wave_wdata_q[55:48];
        if (wave_wstrb_q[7])  mem[wave_word_addr][63:56] <= wave_wdata_q[63:56];
        if (wave_wstrb_q[8])  mem[wave_word_addr][71:64] <= wave_wdata_q[71:64];
        if (wave_wstrb_q[9])  mem[wave_word_addr][79:72] <= wave_wdata_q[79:72];
        if (wave_wstrb_q[10]) mem[wave_word_addr][87:80] <= wave_wdata_q[87:80];
        if (wave_wstrb_q[11]) mem[wave_word_addr][95:88] <= wave_wdata_q[95:88];
        if (wave_wstrb_q[12]) mem[wave_word_addr][103:96] <= wave_wdata_q[103:96];
        if (wave_wstrb_q[13]) mem[wave_word_addr][111:104] <= wave_wdata_q[111:104];
        if (wave_wstrb_q[14]) mem[wave_word_addr][119:112] <= wave_wdata_q[119:112];
        if (wave_wstrb_q[15]) mem[wave_word_addr][127:120] <= wave_wdata_q[127:120];
        if (wave_wstrb_q[16]) mem[wave_word_addr][135:128] <= wave_wdata_q[135:128];
        if (wave_wstrb_q[17]) mem[wave_word_addr][143:136] <= wave_wdata_q[143:136];
        if (wave_wstrb_q[18]) mem[wave_word_addr][151:144] <= wave_wdata_q[151:144];
        if (wave_wstrb_q[19]) mem[wave_word_addr][159:152] <= wave_wdata_q[159:152];
        if (wave_wstrb_q[20]) mem[wave_word_addr][167:160] <= wave_wdata_q[167:160];
        if (wave_wstrb_q[21]) mem[wave_word_addr][175:168] <= wave_wdata_q[175:168];
        if (wave_wstrb_q[22]) mem[wave_word_addr][183:176] <= wave_wdata_q[183:176];
        if (wave_wstrb_q[23]) mem[wave_word_addr][191:184] <= wave_wdata_q[191:184];
        if (wave_wstrb_q[24]) mem[wave_word_addr][199:192] <= wave_wdata_q[199:192];
        if (wave_wstrb_q[25]) mem[wave_word_addr][207:200] <= wave_wdata_q[207:200];
        if (wave_wstrb_q[26]) mem[wave_word_addr][215:208] <= wave_wdata_q[215:208];
        if (wave_wstrb_q[27]) mem[wave_word_addr][223:216] <= wave_wdata_q[223:216];
        if (wave_wstrb_q[28]) mem[wave_word_addr][231:224] <= wave_wdata_q[231:224];
        if (wave_wstrb_q[29]) mem[wave_word_addr][239:232] <= wave_wdata_q[239:232];
        if (wave_wstrb_q[30]) mem[wave_word_addr][247:240] <= wave_wdata_q[247:240];
        if (wave_wstrb_q[31]) mem[wave_word_addr][255:248] <= wave_wdata_q[255:248];
        wave_aw_pending <= 1'b0;
        wave_w_pending  <= 1'b0;
        wave_bvalid_q   <= 1'b1;
      end else if (wave_bvalid_q && S_AXI_WAVE_bready) begin
        wave_bvalid_q <= 1'b0;
      end
      if (dm_ar_fire) begin
        dm_addr_q <= S_AXI_DM_araddr;
        dm_len_q  <= S_AXI_DM_arlen;
        dm_count_q <= S_AXI_DM_arlen + 1'b1;
        dm_active <= 1'b1;
      end else if (dm_active && !dm_rvalid_q && !S_AXI_DM_rready) begin
        // wait for request acceptance
      end
      if (dm_active && !dm_rvalid_q && !dm_ar_fire) begin
        dm_rdata_q <= {mem[dm_word_addr + 1], mem[dm_word_addr]};
        dm_rvalid_q <= 1'b1;
      end
      if (dm_r_fire) begin
        dm_addr_q <= dm_addr_q + 64;
        if (dm_count_q == 8'd1) begin
          dm_active <= 1'b0;
          dm_rvalid_q <= 1'b0;
        end else begin
          dm_count_q <= dm_count_q - 1'b1;
          dm_rvalid_q <= 1'b0;
        end
      end
    end
  end

endmodule
