// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
// -------------------------------------------------------------------------------

`timescale 1ns/1ps

(* BLOCK_STUB = "true" *)
module ddr_custom_xczu47dr_ip (
  c0_init_calib_complete,
  dbg_clk,
  c0_sys_clk_p,
  c0_sys_clk_n,
  dbg_bus,
  c0_ddr4_adr,
  c0_ddr4_ba,
  c0_ddr4_cke,
  c0_ddr4_cs_n,
  c0_ddr4_dm_dbi_n,
  c0_ddr4_dq,
  c0_ddr4_dqs_c,
  c0_ddr4_dqs_t,
  c0_ddr4_odt,
  c0_ddr4_bg,
  c0_ddr4_reset_n,
  c0_ddr4_act_n,
  c0_ddr4_ck_c,
  c0_ddr4_ck_t,
  c0_ddr4_ui_clk,
  c0_ddr4_ui_clk_sync_rst,
  c0_ddr4_aresetn,
  c0_ddr4_s_axi_awid,
  c0_ddr4_s_axi_awaddr,
  c0_ddr4_s_axi_awlen,
  c0_ddr4_s_axi_awsize,
  c0_ddr4_s_axi_awburst,
  c0_ddr4_s_axi_awlock,
  c0_ddr4_s_axi_awcache,
  c0_ddr4_s_axi_awprot,
  c0_ddr4_s_axi_awqos,
  c0_ddr4_s_axi_awvalid,
  c0_ddr4_s_axi_awready,
  c0_ddr4_s_axi_wdata,
  c0_ddr4_s_axi_wstrb,
  c0_ddr4_s_axi_wlast,
  c0_ddr4_s_axi_wvalid,
  c0_ddr4_s_axi_wready,
  c0_ddr4_s_axi_bready,
  c0_ddr4_s_axi_bid,
  c0_ddr4_s_axi_bresp,
  c0_ddr4_s_axi_bvalid,
  c0_ddr4_s_axi_arid,
  c0_ddr4_s_axi_araddr,
  c0_ddr4_s_axi_arlen,
  c0_ddr4_s_axi_arsize,
  c0_ddr4_s_axi_arburst,
  c0_ddr4_s_axi_arlock,
  c0_ddr4_s_axi_arcache,
  c0_ddr4_s_axi_arprot,
  c0_ddr4_s_axi_arqos,
  c0_ddr4_s_axi_arvalid,
  c0_ddr4_s_axi_arready,
  c0_ddr4_s_axi_rready,
  c0_ddr4_s_axi_rlast,
  c0_ddr4_s_axi_rvalid,
  c0_ddr4_s_axi_rresp,
  c0_ddr4_s_axi_rid,
  c0_ddr4_s_axi_rdata,
  sys_rst
);

  (* X_INTERFACE_IGNORE = "true" *)
  output c0_init_calib_complete;
  (* X_INTERFACE_IGNORE = "true" *)
  output dbg_clk;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_clock:1.0 C0_SYS_CLK CLK_P" *)
  (* X_INTERFACE_MODE = "slave C0_SYS_CLK" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME C0_SYS_CLK, BOARD.ASSOCIATED_PARAM C0_CLOCK_BOARD_INTERFACE, CAN_DEBUG false, FREQ_HZ 100000000" *)
  input c0_sys_clk_p;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_clock:1.0 C0_SYS_CLK CLK_N" *)
  input c0_sys_clk_n;
  (* X_INTERFACE_IGNORE = "true" *)
  output [511:0]dbg_bus;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 ADR" *)
  (* X_INTERFACE_MODE = "master C0_DDR4" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME C0_DDR4, BOARD.ASSOCIATED_PARAM C0_DDR4_BOARD_INTERFACE, CAN_DEBUG false, TIMEPERIOD_PS 1250, MEMORY_TYPE COMPONENTS, MEMORY_PART , DATA_WIDTH 8, CS_ENABLED true, DATA_MASK_ENABLED true, SLOT Single, CUSTOM_PARTS , MEM_ADDR_MAP ROW_COLUMN_BANK, BURST_LENGTH 8, AXI_ARBITRATION_SCHEME TDM, CAS_LATENCY 11, CAS_WRITE_LATENCY 11" *)
  output [16:0]c0_ddr4_adr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 BA" *)
  output [1:0]c0_ddr4_ba;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 CKE" *)
  output [0:0]c0_ddr4_cke;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 CS_N" *)
  output [0:0]c0_ddr4_cs_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 DM_N" *)
  inout [7:0]c0_ddr4_dm_dbi_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 DQ" *)
  inout [63:0]c0_ddr4_dq;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 DQS_C" *)
  inout [7:0]c0_ddr4_dqs_c;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 DQS_T" *)
  inout [7:0]c0_ddr4_dqs_t;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 ODT" *)
  output [0:0]c0_ddr4_odt;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 BG" *)
  output [0:0]c0_ddr4_bg;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 RESET_N" *)
  output c0_ddr4_reset_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 ACT_N" *)
  output c0_ddr4_act_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 CK_C" *)
  output [0:0]c0_ddr4_ck_c;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddr4:1.0 C0_DDR4 CK_T" *)
  output [0:0]c0_ddr4_ck_t;
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 C0_DDR4_CLOCK CLK" *)
  (* X_INTERFACE_MODE = "master C0_DDR4_CLOCK" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME C0_DDR4_CLOCK, FREQ_HZ 3e+08, PHASE 0.00, ASSOCIATED_BUSIF C0_DDR4_S_AXI:C0_DDR4_S_AXI_CTRL, ASSOCIATED_RESET c0_ddr4_aresetn:c0_ddr4_ui_clk_sync_rst, FREQ_TOLERANCE_HZ 0, CLK_DOMAIN , ASSOCIATED_PORT , INSERT_VIP 0" *)
  output c0_ddr4_ui_clk;
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 C0_DDR4_RESET RST" *)
  (* X_INTERFACE_MODE = "master C0_DDR4_RESET" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME C0_DDR4_RESET, POLARITY ACTIVE_HIGH, INSERT_VIP 0" *)
  output c0_ddr4_ui_clk_sync_rst;
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 C0_DDR4_ARESETN RST" *)
  (* X_INTERFACE_MODE = "slave C0_DDR4_ARESETN" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME C0_DDR4_ARESETN, POLARITY ACTIVE_LOW, INSERT_VIP 0" *)
  input c0_ddr4_aresetn;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI AWID" *)
  (* X_INTERFACE_MODE = "slave C0_DDR4_S_AXI" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME C0_DDR4_S_AXI, FREQ_HZ 3e+08, DATA_WIDTH 512, PROTOCOL AXI4, ID_WIDTH 1, ADDR_WIDTH 33, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 1, HAS_LOCK 1, HAS_PROT 1, HAS_CACHE 1, HAS_QOS 1, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 1, NUM_READ_OUTSTANDING 2, NUM_WRITE_OUTSTANDING 2, MAX_BURST_LENGTH 256, PHASE 0.0, CLK_DOMAIN , NUM_READ_THREADS 1, NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0" *)
  input [0:0]c0_ddr4_s_axi_awid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI AWADDR" *)
  input [32:0]c0_ddr4_s_axi_awaddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI AWLEN" *)
  input [7:0]c0_ddr4_s_axi_awlen;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI AWSIZE" *)
  input [2:0]c0_ddr4_s_axi_awsize;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI AWBURST" *)
  input [1:0]c0_ddr4_s_axi_awburst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI AWLOCK" *)
  input [0:0]c0_ddr4_s_axi_awlock;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI AWCACHE" *)
  input [3:0]c0_ddr4_s_axi_awcache;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI AWPROT" *)
  input [2:0]c0_ddr4_s_axi_awprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI AWQOS" *)
  input [3:0]c0_ddr4_s_axi_awqos;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI AWVALID" *)
  input c0_ddr4_s_axi_awvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI AWREADY" *)
  output c0_ddr4_s_axi_awready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI WDATA" *)
  input [511:0]c0_ddr4_s_axi_wdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI WSTRB" *)
  input [63:0]c0_ddr4_s_axi_wstrb;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI WLAST" *)
  input c0_ddr4_s_axi_wlast;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI WVALID" *)
  input c0_ddr4_s_axi_wvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI WREADY" *)
  output c0_ddr4_s_axi_wready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI BREADY" *)
  input c0_ddr4_s_axi_bready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI BID" *)
  output [0:0]c0_ddr4_s_axi_bid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI BRESP" *)
  output [1:0]c0_ddr4_s_axi_bresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI BVALID" *)
  output c0_ddr4_s_axi_bvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI ARID" *)
  input [0:0]c0_ddr4_s_axi_arid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI ARADDR" *)
  input [32:0]c0_ddr4_s_axi_araddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI ARLEN" *)
  input [7:0]c0_ddr4_s_axi_arlen;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI ARSIZE" *)
  input [2:0]c0_ddr4_s_axi_arsize;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI ARBURST" *)
  input [1:0]c0_ddr4_s_axi_arburst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI ARLOCK" *)
  input [0:0]c0_ddr4_s_axi_arlock;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI ARCACHE" *)
  input [3:0]c0_ddr4_s_axi_arcache;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI ARPROT" *)
  input [2:0]c0_ddr4_s_axi_arprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI ARQOS" *)
  input [3:0]c0_ddr4_s_axi_arqos;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI ARVALID" *)
  input c0_ddr4_s_axi_arvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI ARREADY" *)
  output c0_ddr4_s_axi_arready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI RREADY" *)
  input c0_ddr4_s_axi_rready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI RLAST" *)
  output c0_ddr4_s_axi_rlast;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI RVALID" *)
  output c0_ddr4_s_axi_rvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI RRESP" *)
  output [1:0]c0_ddr4_s_axi_rresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI RID" *)
  output [0:0]c0_ddr4_s_axi_rid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 C0_DDR4_S_AXI RDATA" *)
  output [511:0]c0_ddr4_s_axi_rdata;
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 SYSTEM_RESET RST" *)
  (* X_INTERFACE_MODE = "slave SYSTEM_RESET" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME SYSTEM_RESET, POLARITY ACTIVE_HIGH, BOARD.ASSOCIATED_PARAM RESET_BOARD_INTERFACE, INSERT_VIP 0" *)
  input sys_rst;

  // stub module has no contents


  reg sim_ddr_clk = 1'b0;
  always #2 sim_ddr_clk = ~sim_ddr_clk;
  assign c0_init_calib_complete = 1'b1;
  assign dbg_clk = 0;
  assign c0_ddr4_reset_n = 0;
  assign c0_ddr4_act_n = 0;
  assign c0_ddr4_ui_clk = sim_ddr_clk;
  assign c0_ddr4_ui_clk_sync_rst = 0;
  assign c0_ddr4_s_axi_awready = 0;
  assign c0_ddr4_s_axi_wready = 0;
  assign c0_ddr4_s_axi_bvalid = 0;
  assign c0_ddr4_s_axi_arready = 0;
  assign c0_ddr4_s_axi_rlast = 0;
  assign c0_ddr4_s_axi_rvalid = 0;

endmodule
