// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
// -------------------------------------------------------------------------------

`timescale 1ns/1ps

(* BLOCK_STUB = "true" *)
module rfdc_custom_xczu47dr_ip (
  clk_dac0,
  clk_dac1,
  dac2_clk_p,
  dac2_clk_n,
  clk_dac2,
  clk_dac3,
  s_axi_aclk,
  s_axi_aresetn,
  s_axi_awaddr,
  s_axi_awvalid,
  s_axi_awready,
  s_axi_wdata,
  s_axi_wstrb,
  s_axi_wvalid,
  s_axi_wready,
  s_axi_bresp,
  s_axi_bvalid,
  s_axi_bready,
  s_axi_araddr,
  s_axi_arvalid,
  s_axi_arready,
  s_axi_rdata,
  s_axi_rresp,
  s_axi_rvalid,
  s_axi_rready,
  irq,
  sysref_in_p,
  sysref_in_n,
  user_sysref_dac,
  vout00_p,
  vout00_n,
  vout02_p,
  vout02_n,
  vout10_p,
  vout10_n,
  vout12_p,
  vout12_n,
  vout20_p,
  vout20_n,
  vout22_p,
  vout22_n,
  vout30_p,
  vout30_n,
  vout32_p,
  vout32_n,
  s0_axis_aresetn,
  s0_axis_aclk,
  s00_axis_tdata,
  s00_axis_tvalid,
  s00_axis_tready,
  s01_axis_tdata,
  s01_axis_tvalid,
  s01_axis_tready,
  s02_axis_tdata,
  s02_axis_tvalid,
  s02_axis_tready,
  s03_axis_tdata,
  s03_axis_tvalid,
  s03_axis_tready,
  s1_axis_aresetn,
  s1_axis_aclk,
  s10_axis_tdata,
  s10_axis_tvalid,
  s10_axis_tready,
  s11_axis_tdata,
  s11_axis_tvalid,
  s11_axis_tready,
  s12_axis_tdata,
  s12_axis_tvalid,
  s12_axis_tready,
  s13_axis_tdata,
  s13_axis_tvalid,
  s13_axis_tready,
  s2_axis_aresetn,
  s2_axis_aclk,
  s20_axis_tdata,
  s20_axis_tvalid,
  s20_axis_tready,
  s21_axis_tdata,
  s21_axis_tvalid,
  s21_axis_tready,
  s22_axis_tdata,
  s22_axis_tvalid,
  s22_axis_tready,
  s23_axis_tdata,
  s23_axis_tvalid,
  s23_axis_tready,
  s3_axis_aresetn,
  s3_axis_aclk,
  s30_axis_tdata,
  s30_axis_tvalid,
  s30_axis_tready,
  s31_axis_tdata,
  s31_axis_tvalid,
  s31_axis_tready,
  s32_axis_tdata,
  s32_axis_tvalid,
  s32_axis_tready,
  s33_axis_tdata,
  s33_axis_tvalid,
  s33_axis_tready,
  dac00_nco_freq,
  dac01_nco_freq,
  dac02_nco_freq,
  dac03_nco_freq,
  dac00_nco_phase,
  dac01_nco_phase,
  dac02_nco_phase,
  dac03_nco_phase,
  dac00_nco_phase_rst,
  dac01_nco_phase_rst,
  dac02_nco_phase_rst,
  dac03_nco_phase_rst,
  dac00_nco_update_en,
  dac01_nco_update_en,
  dac02_nco_update_en,
  dac03_nco_update_en,
  dac0_nco_update_req,
  dac0_sysref_int_gating,
  dac0_sysref_int_reenable,
  dac0_nco_update_busy,
  dac10_nco_freq,
  dac11_nco_freq,
  dac12_nco_freq,
  dac13_nco_freq,
  dac10_nco_phase,
  dac11_nco_phase,
  dac12_nco_phase,
  dac13_nco_phase,
  dac10_nco_phase_rst,
  dac11_nco_phase_rst,
  dac12_nco_phase_rst,
  dac13_nco_phase_rst,
  dac10_nco_update_en,
  dac11_nco_update_en,
  dac12_nco_update_en,
  dac13_nco_update_en,
  dac1_nco_update_req,
  dac1_nco_update_busy,
  dac20_nco_freq,
  dac21_nco_freq,
  dac22_nco_freq,
  dac23_nco_freq,
  dac20_nco_phase,
  dac21_nco_phase,
  dac22_nco_phase,
  dac23_nco_phase,
  dac20_nco_phase_rst,
  dac21_nco_phase_rst,
  dac22_nco_phase_rst,
  dac23_nco_phase_rst,
  dac20_nco_update_en,
  dac21_nco_update_en,
  dac22_nco_update_en,
  dac23_nco_update_en,
  dac2_nco_update_req,
  dac2_nco_update_busy,
  dac30_nco_freq,
  dac31_nco_freq,
  dac32_nco_freq,
  dac33_nco_freq,
  dac30_nco_phase,
  dac31_nco_phase,
  dac32_nco_phase,
  dac33_nco_phase,
  dac30_nco_phase_rst,
  dac31_nco_phase_rst,
  dac32_nco_phase_rst,
  dac33_nco_phase_rst,
  dac30_nco_update_en,
  dac31_nco_update_en,
  dac32_nco_update_en,
  dac33_nco_update_en,
  dac3_nco_update_req,
  dac3_nco_update_busy
);

  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_dac0 CLK" *)
  (* X_INTERFACE_MODE = "master clk_dac0" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk_dac0, FREQ_HZ 100000000, FREQ_TOLERANCE_HZ 0, PHASE 0.0, CLK_DOMAIN , ASSOCIATED_BUSIF , ASSOCIATED_PORT , ASSOCIATED_RESET , INSERT_VIP 0" *)
  output clk_dac0;
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_dac1 CLK" *)
  (* X_INTERFACE_MODE = "master clk_dac1" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk_dac1, FREQ_HZ 100000000, FREQ_TOLERANCE_HZ 0, PHASE 0.0, CLK_DOMAIN , ASSOCIATED_BUSIF , ASSOCIATED_PORT , ASSOCIATED_RESET , INSERT_VIP 0" *)
  output clk_dac1;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_clock:1.0 dac2_clk CLK_P" *)
  (* X_INTERFACE_MODE = "slave dac2_clk" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME dac2_clk, CAN_DEBUG false, FREQ_HZ 100000000" *)
  input dac2_clk_p;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_clock:1.0 dac2_clk CLK_N" *)
  input dac2_clk_n;
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_dac2 CLK" *)
  (* X_INTERFACE_MODE = "master clk_dac2" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk_dac2, FREQ_HZ 100000000, FREQ_TOLERANCE_HZ 0, PHASE 0.0, CLK_DOMAIN , ASSOCIATED_BUSIF , ASSOCIATED_PORT , ASSOCIATED_RESET , INSERT_VIP 0" *)
  output clk_dac2;
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_dac3 CLK" *)
  (* X_INTERFACE_MODE = "master clk_dac3" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk_dac3, FREQ_HZ 100000000, FREQ_TOLERANCE_HZ 0, PHASE 0.0, CLK_DOMAIN , ASSOCIATED_BUSIF , ASSOCIATED_PORT , ASSOCIATED_RESET , INSERT_VIP 0" *)
  output clk_dac3;
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
  (* X_INTERFACE_MODE = "slave s_axi_aclk" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi_aclk, ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn, FREQ_HZ 100000000, FREQ_TOLERANCE_HZ 0, PHASE 0.0, CLK_DOMAIN , ASSOCIATED_PORT , INSERT_VIP 0" *)
  input s_axi_aclk;
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
  (* X_INTERFACE_MODE = "slave s_axi_aresetn" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi_aresetn, POLARITY ACTIVE_LOW, INSERT_VIP 0" *)
  input s_axi_aresetn;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *)
  (* X_INTERFACE_MODE = "slave s_axi" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi, DATA_WIDTH 32, PROTOCOL AXI4LITE, FREQ_HZ 100000000, ID_WIDTH 0, ADDR_WIDTH 18, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, MAX_BURST_LENGTH 1, PHASE 0.0, CLK_DOMAIN , NUM_READ_THREADS 1, NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0" *)
  input [17:0]s_axi_awaddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *)
  input s_axi_awvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *)
  output s_axi_awready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *)
  input [31:0]s_axi_wdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *)
  input [3:0]s_axi_wstrb;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *)
  input s_axi_wvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *)
  output s_axi_wready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *)
  output [1:0]s_axi_bresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *)
  output s_axi_bvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *)
  input s_axi_bready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *)
  input [17:0]s_axi_araddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *)
  input s_axi_arvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *)
  output s_axi_arready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *)
  output [31:0]s_axi_rdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *)
  output [1:0]s_axi_rresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *)
  output s_axi_rvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *)
  input s_axi_rready;
  (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq INTERRUPT" *)
  (* X_INTERFACE_MODE = "master irq" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME irq, SENSITIVITY EDGE_RISING, PortWidth 1" *)
  output irq;
  (* X_INTERFACE_INFO = "xilinx.com:display_usp_rf_data_converter:diff_pins:1.0 sysref_in diff_p" *)
  (* X_INTERFACE_MODE = "slave sysref_in" *)
  input sysref_in_p;
  (* X_INTERFACE_INFO = "xilinx.com:display_usp_rf_data_converter:diff_pins:1.0 sysref_in diff_n" *)
  input sysref_in_n;
  (* X_INTERFACE_IGNORE = "true" *)
  input user_sysref_dac;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_analog_io:1.0 vout00 V_P" *)
  (* X_INTERFACE_MODE = "master vout00" *)
  output vout00_p;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_analog_io:1.0 vout00 V_N" *)
  output vout00_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_analog_io:1.0 vout02 V_P" *)
  (* X_INTERFACE_MODE = "master vout02" *)
  output vout02_p;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_analog_io:1.0 vout02 V_N" *)
  output vout02_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_analog_io:1.0 vout10 V_P" *)
  (* X_INTERFACE_MODE = "master vout10" *)
  output vout10_p;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_analog_io:1.0 vout10 V_N" *)
  output vout10_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_analog_io:1.0 vout12 V_P" *)
  (* X_INTERFACE_MODE = "master vout12" *)
  output vout12_p;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_analog_io:1.0 vout12 V_N" *)
  output vout12_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_analog_io:1.0 vout20 V_P" *)
  (* X_INTERFACE_MODE = "master vout20" *)
  output vout20_p;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_analog_io:1.0 vout20 V_N" *)
  output vout20_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_analog_io:1.0 vout22 V_P" *)
  (* X_INTERFACE_MODE = "master vout22" *)
  output vout22_p;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_analog_io:1.0 vout22 V_N" *)
  output vout22_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_analog_io:1.0 vout30 V_P" *)
  (* X_INTERFACE_MODE = "master vout30" *)
  output vout30_p;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_analog_io:1.0 vout30 V_N" *)
  output vout30_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_analog_io:1.0 vout32 V_P" *)
  (* X_INTERFACE_MODE = "master vout32" *)
  output vout32_p;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_analog_io:1.0 vout32 V_N" *)
  output vout32_n;
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s0_axis_aresetn RST" *)
  (* X_INTERFACE_MODE = "slave s0_axis_aresetn" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s0_axis_aresetn, POLARITY ACTIVE_LOW, INSERT_VIP 0" *)
  input s0_axis_aresetn;
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s0_axis_aclk CLK" *)
  (* X_INTERFACE_MODE = "slave s0_axis_aclk" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s0_axis_aclk, ASSOCIATED_BUSIF s03_axis:s02_axis:s01_axis:s00_axis, ASSOCIATED_RESET s0_axis_aresetn, FREQ_HZ 100000000, FREQ_TOLERANCE_HZ 0, PHASE 0.0, CLK_DOMAIN , ASSOCIATED_PORT , INSERT_VIP 0" *)
  input s0_axis_aclk;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s00_axis TDATA" *)
  (* X_INTERFACE_MODE = "slave s00_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s00_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 100000000, PHASE 0.0, CLK_DOMAIN , LAYERED_METADATA undef, INSERT_VIP 0" *)
  input [255:0]s00_axis_tdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s00_axis TVALID" *)
  input s00_axis_tvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s00_axis TREADY" *)
  output s00_axis_tready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s01_axis TDATA" *)
  (* X_INTERFACE_MODE = "slave s01_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s01_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 100000000, PHASE 0.0, CLK_DOMAIN , LAYERED_METADATA undef, INSERT_VIP 0" *)
  input [255:0]s01_axis_tdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s01_axis TVALID" *)
  input s01_axis_tvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s01_axis TREADY" *)
  output s01_axis_tready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s02_axis TDATA" *)
  (* X_INTERFACE_MODE = "slave s02_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s02_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 100000000, PHASE 0.0, CLK_DOMAIN , LAYERED_METADATA undef, INSERT_VIP 0" *)
  input [255:0]s02_axis_tdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s02_axis TVALID" *)
  input s02_axis_tvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s02_axis TREADY" *)
  output s02_axis_tready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s03_axis TDATA" *)
  (* X_INTERFACE_MODE = "slave s03_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s03_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 100000000, PHASE 0.0, CLK_DOMAIN , LAYERED_METADATA undef, INSERT_VIP 0" *)
  input [255:0]s03_axis_tdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s03_axis TVALID" *)
  input s03_axis_tvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s03_axis TREADY" *)
  output s03_axis_tready;
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s1_axis_aresetn RST" *)
  (* X_INTERFACE_MODE = "slave s1_axis_aresetn" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s1_axis_aresetn, POLARITY ACTIVE_LOW, INSERT_VIP 0" *)
  input s1_axis_aresetn;
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s1_axis_aclk CLK" *)
  (* X_INTERFACE_MODE = "slave s1_axis_aclk" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s1_axis_aclk, ASSOCIATED_BUSIF s13_axis:s12_axis:s11_axis:s10_axis, ASSOCIATED_RESET s1_axis_aresetn, FREQ_HZ 100000000, FREQ_TOLERANCE_HZ 0, PHASE 0.0, CLK_DOMAIN , ASSOCIATED_PORT , INSERT_VIP 0" *)
  input s1_axis_aclk;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s10_axis TDATA" *)
  (* X_INTERFACE_MODE = "slave s10_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s10_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 100000000, PHASE 0.0, CLK_DOMAIN , LAYERED_METADATA undef, INSERT_VIP 0" *)
  input [255:0]s10_axis_tdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s10_axis TVALID" *)
  input s10_axis_tvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s10_axis TREADY" *)
  output s10_axis_tready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s11_axis TDATA" *)
  (* X_INTERFACE_MODE = "slave s11_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s11_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 100000000, PHASE 0.0, CLK_DOMAIN , LAYERED_METADATA undef, INSERT_VIP 0" *)
  input [255:0]s11_axis_tdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s11_axis TVALID" *)
  input s11_axis_tvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s11_axis TREADY" *)
  output s11_axis_tready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s12_axis TDATA" *)
  (* X_INTERFACE_MODE = "slave s12_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s12_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 100000000, PHASE 0.0, CLK_DOMAIN , LAYERED_METADATA undef, INSERT_VIP 0" *)
  input [255:0]s12_axis_tdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s12_axis TVALID" *)
  input s12_axis_tvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s12_axis TREADY" *)
  output s12_axis_tready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s13_axis TDATA" *)
  (* X_INTERFACE_MODE = "slave s13_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s13_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 100000000, PHASE 0.0, CLK_DOMAIN , LAYERED_METADATA undef, INSERT_VIP 0" *)
  input [255:0]s13_axis_tdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s13_axis TVALID" *)
  input s13_axis_tvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s13_axis TREADY" *)
  output s13_axis_tready;
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s2_axis_aresetn RST" *)
  (* X_INTERFACE_MODE = "slave s2_axis_aresetn" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s2_axis_aresetn, POLARITY ACTIVE_LOW, INSERT_VIP 0" *)
  input s2_axis_aresetn;
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s2_axis_aclk CLK" *)
  (* X_INTERFACE_MODE = "slave s2_axis_aclk" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s2_axis_aclk, ASSOCIATED_BUSIF s23_axis:s22_axis:s21_axis:s20_axis, ASSOCIATED_RESET s2_axis_aresetn, FREQ_HZ 100000000, FREQ_TOLERANCE_HZ 0, PHASE 0.0, CLK_DOMAIN , ASSOCIATED_PORT , INSERT_VIP 0" *)
  input s2_axis_aclk;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s20_axis TDATA" *)
  (* X_INTERFACE_MODE = "slave s20_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s20_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 100000000, PHASE 0.0, CLK_DOMAIN , LAYERED_METADATA undef, INSERT_VIP 0" *)
  input [255:0]s20_axis_tdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s20_axis TVALID" *)
  input s20_axis_tvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s20_axis TREADY" *)
  output s20_axis_tready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s21_axis TDATA" *)
  (* X_INTERFACE_MODE = "slave s21_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s21_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 100000000, PHASE 0.0, CLK_DOMAIN , LAYERED_METADATA undef, INSERT_VIP 0" *)
  input [255:0]s21_axis_tdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s21_axis TVALID" *)
  input s21_axis_tvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s21_axis TREADY" *)
  output s21_axis_tready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s22_axis TDATA" *)
  (* X_INTERFACE_MODE = "slave s22_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s22_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 100000000, PHASE 0.0, CLK_DOMAIN , LAYERED_METADATA undef, INSERT_VIP 0" *)
  input [255:0]s22_axis_tdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s22_axis TVALID" *)
  input s22_axis_tvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s22_axis TREADY" *)
  output s22_axis_tready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s23_axis TDATA" *)
  (* X_INTERFACE_MODE = "slave s23_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s23_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 100000000, PHASE 0.0, CLK_DOMAIN , LAYERED_METADATA undef, INSERT_VIP 0" *)
  input [255:0]s23_axis_tdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s23_axis TVALID" *)
  input s23_axis_tvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s23_axis TREADY" *)
  output s23_axis_tready;
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s3_axis_aresetn RST" *)
  (* X_INTERFACE_MODE = "slave s3_axis_aresetn" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s3_axis_aresetn, POLARITY ACTIVE_LOW, INSERT_VIP 0" *)
  input s3_axis_aresetn;
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s3_axis_aclk CLK" *)
  (* X_INTERFACE_MODE = "slave s3_axis_aclk" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s3_axis_aclk, ASSOCIATED_BUSIF s33_axis:s32_axis:s31_axis:s30_axis, ASSOCIATED_RESET s3_axis_aresetn, FREQ_HZ 100000000, FREQ_TOLERANCE_HZ 0, PHASE 0.0, CLK_DOMAIN , ASSOCIATED_PORT , INSERT_VIP 0" *)
  input s3_axis_aclk;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s30_axis TDATA" *)
  (* X_INTERFACE_MODE = "slave s30_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s30_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 100000000, PHASE 0.0, CLK_DOMAIN , LAYERED_METADATA undef, INSERT_VIP 0" *)
  input [255:0]s30_axis_tdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s30_axis TVALID" *)
  input s30_axis_tvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s30_axis TREADY" *)
  output s30_axis_tready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s31_axis TDATA" *)
  (* X_INTERFACE_MODE = "slave s31_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s31_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 100000000, PHASE 0.0, CLK_DOMAIN , LAYERED_METADATA undef, INSERT_VIP 0" *)
  input [255:0]s31_axis_tdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s31_axis TVALID" *)
  input s31_axis_tvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s31_axis TREADY" *)
  output s31_axis_tready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s32_axis TDATA" *)
  (* X_INTERFACE_MODE = "slave s32_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s32_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 100000000, PHASE 0.0, CLK_DOMAIN , LAYERED_METADATA undef, INSERT_VIP 0" *)
  input [255:0]s32_axis_tdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s32_axis TVALID" *)
  input s32_axis_tvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s32_axis TREADY" *)
  output s32_axis_tready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s33_axis TDATA" *)
  (* X_INTERFACE_MODE = "slave s33_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s33_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 100000000, PHASE 0.0, CLK_DOMAIN , LAYERED_METADATA undef, INSERT_VIP 0" *)
  input [255:0]s33_axis_tdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s33_axis TVALID" *)
  input s33_axis_tvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s33_axis TREADY" *)
  output s33_axis_tready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac0_nco CONVERTER0_NCO_FREQ" *)
  (* X_INTERFACE_MODE = "slave dac0_nco" *)
  input [47:0]dac00_nco_freq;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac0_nco CONVERTER1_NCO_FREQ" *)
  input [47:0]dac01_nco_freq;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac0_nco CONVERTER2_NCO_FREQ" *)
  input [47:0]dac02_nco_freq;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac0_nco CONVERTER3_NCO_FREQ" *)
  input [47:0]dac03_nco_freq;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac0_nco CONVERTER0_NCO_PHASE" *)
  input [17:0]dac00_nco_phase;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac0_nco CONVERTER1_NCO_PHASE" *)
  input [17:0]dac01_nco_phase;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac0_nco CONVERTER2_NCO_PHASE" *)
  input [17:0]dac02_nco_phase;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac0_nco CONVERTER3_NCO_PHASE" *)
  input [17:0]dac03_nco_phase;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac0_nco CONVERTER0_PHASE_RESET" *)
  input dac00_nco_phase_rst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac0_nco CONVERTER1_PHASE_RESET" *)
  input dac01_nco_phase_rst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac0_nco CONVERTER2_PHASE_RESET" *)
  input dac02_nco_phase_rst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac0_nco CONVERTER3_PHASE_RESET" *)
  input dac03_nco_phase_rst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac0_nco CONVERTER0_UPDATE_EN" *)
  input [5:0]dac00_nco_update_en;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac0_nco CONVERTER1_UPDATE_EN" *)
  input [5:0]dac01_nco_update_en;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac0_nco CONVERTER2_UPDATE_EN" *)
  input [5:0]dac02_nco_update_en;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac0_nco CONVERTER3_UPDATE_EN" *)
  input [5:0]dac03_nco_update_en;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac0_nco NCO_UPDATE_REQUEST" *)
  input dac0_nco_update_req;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac0_nco SYSREF_INT_GATING" *)
  input dac0_sysref_int_gating;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac0_nco SYSREF_INT_REENABLE" *)
  input dac0_sysref_int_reenable;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac0_nco NCO_UPDATE_BUSY" *)
  output [1:0]dac0_nco_update_busy;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac1_nco CONVERTER0_NCO_FREQ" *)
  (* X_INTERFACE_MODE = "slave dac1_nco" *)
  input [47:0]dac10_nco_freq;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac1_nco CONVERTER1_NCO_FREQ" *)
  input [47:0]dac11_nco_freq;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac1_nco CONVERTER2_NCO_FREQ" *)
  input [47:0]dac12_nco_freq;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac1_nco CONVERTER3_NCO_FREQ" *)
  input [47:0]dac13_nco_freq;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac1_nco CONVERTER0_NCO_PHASE" *)
  input [17:0]dac10_nco_phase;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac1_nco CONVERTER1_NCO_PHASE" *)
  input [17:0]dac11_nco_phase;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac1_nco CONVERTER2_NCO_PHASE" *)
  input [17:0]dac12_nco_phase;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac1_nco CONVERTER3_NCO_PHASE" *)
  input [17:0]dac13_nco_phase;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac1_nco CONVERTER0_PHASE_RESET" *)
  input dac10_nco_phase_rst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac1_nco CONVERTER1_PHASE_RESET" *)
  input dac11_nco_phase_rst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac1_nco CONVERTER2_PHASE_RESET" *)
  input dac12_nco_phase_rst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac1_nco CONVERTER3_PHASE_RESET" *)
  input dac13_nco_phase_rst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac1_nco CONVERTER0_UPDATE_EN" *)
  input [5:0]dac10_nco_update_en;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac1_nco CONVERTER1_UPDATE_EN" *)
  input [5:0]dac11_nco_update_en;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac1_nco CONVERTER2_UPDATE_EN" *)
  input [5:0]dac12_nco_update_en;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac1_nco CONVERTER3_UPDATE_EN" *)
  input [5:0]dac13_nco_update_en;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac1_nco NCO_UPDATE_REQUEST" *)
  input dac1_nco_update_req;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac1_nco NCO_UPDATE_BUSY" *)
  output dac1_nco_update_busy;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac2_nco CONVERTER0_NCO_FREQ" *)
  (* X_INTERFACE_MODE = "slave dac2_nco" *)
  input [47:0]dac20_nco_freq;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac2_nco CONVERTER1_NCO_FREQ" *)
  input [47:0]dac21_nco_freq;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac2_nco CONVERTER2_NCO_FREQ" *)
  input [47:0]dac22_nco_freq;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac2_nco CONVERTER3_NCO_FREQ" *)
  input [47:0]dac23_nco_freq;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac2_nco CONVERTER0_NCO_PHASE" *)
  input [17:0]dac20_nco_phase;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac2_nco CONVERTER1_NCO_PHASE" *)
  input [17:0]dac21_nco_phase;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac2_nco CONVERTER2_NCO_PHASE" *)
  input [17:0]dac22_nco_phase;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac2_nco CONVERTER3_NCO_PHASE" *)
  input [17:0]dac23_nco_phase;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac2_nco CONVERTER0_PHASE_RESET" *)
  input dac20_nco_phase_rst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac2_nco CONVERTER1_PHASE_RESET" *)
  input dac21_nco_phase_rst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac2_nco CONVERTER2_PHASE_RESET" *)
  input dac22_nco_phase_rst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac2_nco CONVERTER3_PHASE_RESET" *)
  input dac23_nco_phase_rst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac2_nco CONVERTER0_UPDATE_EN" *)
  input [5:0]dac20_nco_update_en;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac2_nco CONVERTER1_UPDATE_EN" *)
  input [5:0]dac21_nco_update_en;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac2_nco CONVERTER2_UPDATE_EN" *)
  input [5:0]dac22_nco_update_en;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac2_nco CONVERTER3_UPDATE_EN" *)
  input [5:0]dac23_nco_update_en;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac2_nco NCO_UPDATE_REQUEST" *)
  input dac2_nco_update_req;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac2_nco NCO_UPDATE_BUSY" *)
  output dac2_nco_update_busy;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac3_nco CONVERTER0_NCO_FREQ" *)
  (* X_INTERFACE_MODE = "slave dac3_nco" *)
  input [47:0]dac30_nco_freq;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac3_nco CONVERTER1_NCO_FREQ" *)
  input [47:0]dac31_nco_freq;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac3_nco CONVERTER2_NCO_FREQ" *)
  input [47:0]dac32_nco_freq;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac3_nco CONVERTER3_NCO_FREQ" *)
  input [47:0]dac33_nco_freq;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac3_nco CONVERTER0_NCO_PHASE" *)
  input [17:0]dac30_nco_phase;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac3_nco CONVERTER1_NCO_PHASE" *)
  input [17:0]dac31_nco_phase;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac3_nco CONVERTER2_NCO_PHASE" *)
  input [17:0]dac32_nco_phase;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac3_nco CONVERTER3_NCO_PHASE" *)
  input [17:0]dac33_nco_phase;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac3_nco CONVERTER0_PHASE_RESET" *)
  input dac30_nco_phase_rst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac3_nco CONVERTER1_PHASE_RESET" *)
  input dac31_nco_phase_rst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac3_nco CONVERTER2_PHASE_RESET" *)
  input dac32_nco_phase_rst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac3_nco CONVERTER3_PHASE_RESET" *)
  input dac33_nco_phase_rst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac3_nco CONVERTER0_UPDATE_EN" *)
  input [5:0]dac30_nco_update_en;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac3_nco CONVERTER1_UPDATE_EN" *)
  input [5:0]dac31_nco_update_en;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac3_nco CONVERTER2_UPDATE_EN" *)
  input [5:0]dac32_nco_update_en;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac3_nco CONVERTER3_UPDATE_EN" *)
  input [5:0]dac33_nco_update_en;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac3_nco NCO_UPDATE_REQUEST" *)
  input dac3_nco_update_req;
  (* X_INTERFACE_INFO = "xilinx.com:interface:rfdc_nco_pins:1.0 dac3_nco NCO_UPDATE_BUSY" *)
  output dac3_nco_update_busy;

  // stub module has no contents


  reg sim_dac_clk = 1'b0;
  always #10 sim_dac_clk = ~sim_dac_clk;
  reg sim_axis_ready = 1'b1;
  assign clk_dac0 = sim_dac_clk;
  assign clk_dac1 = sim_dac_clk;
  assign clk_dac2 = sim_dac_clk;
  assign clk_dac3 = sim_dac_clk;
  // -------------------------------------------------------------------
  // Minimal RFDC AXI4-Lite control-plane model.
  //
  // The production RFDC configuration path writes converter control
  // registers and verifies them by read-back.  A real converter returns the
  // value it was written, so a plain register file reproduces that contract.
  // Two device facts are modelled explicitly rather than as fabric state:
  //   * a DAC tile CURRENT_STATE read reports 0xF (tile powered and running);
  //   * a CFG3 (VOP/bias) register that has never been written reports the
  //     calibrated quiescent code 0x6D00, which is the value the
  //     configuration FSM uses to derive the present 1400 uA operating point
  //     without re-running a current ramp.
  // -------------------------------------------------------------------
  localparam integer RFDC_REG_WORDS = 16384;
  localparam [17:0]  RFDC_OFF_CURRENT_STATE = 18'h00C;
  localparam [17:0]  RFDC_OFF_CFG3          = 18'h1D0;
  localparam [31:0]  RFDC_CFG3_QUIESCENT    = 32'h0000_6D00;

  reg [31:0] rfdc_regs [0:RFDC_REG_WORDS-1];
  reg        rfdc_reg_written [0:RFDC_REG_WORDS-1];
  reg        aw_pending;
  reg [17:0] aw_addr_q;
  reg        w_pending;
  reg [31:0] w_data_q;
  reg [3:0]  w_strb_q;
  reg        bvalid_q;
  reg        rvalid_q;
  reg [31:0] rdata_q;

  wire aw_fire = s_axi_awvalid && s_axi_awready;
  wire w_fire  = s_axi_wvalid  && s_axi_wready;

  assign s_axi_awready = !aw_pending && !bvalid_q;
  assign s_axi_wready  = !w_pending  && !bvalid_q;
  assign s_axi_bvalid  = bvalid_q;
  assign s_axi_bresp   = 2'b00;
  assign s_axi_arready = !rvalid_q;
  assign s_axi_rvalid  = rvalid_q;
  assign s_axi_rdata   = rdata_q;
  assign s_axi_rresp   = 2'b00;

  function [31:0] rfdc_reg_read(input [17:0] addr);
    integer idx;
    begin
      idx = addr[15:2];
      if ((addr & 18'h7FF) == RFDC_OFF_CURRENT_STATE)
        rfdc_reg_read = 32'h0000_000F;
      else if (((addr & 18'h7FF) == RFDC_OFF_CFG3) && !rfdc_reg_written[idx])
        rfdc_reg_read = RFDC_CFG3_QUIESCENT;
      else
        rfdc_reg_read = rfdc_regs[idx];
    end
  endfunction

  integer ri;
  reg [17:0] commit_addr;
  reg [31:0] commit_data;
  reg [3:0]  commit_strb;
  reg [31:0] commit_word;
  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      aw_pending <= 1'b0;
      w_pending  <= 1'b0;
      bvalid_q   <= 1'b0;
      rvalid_q   <= 1'b0;
      aw_addr_q  <= 18'd0;
      w_data_q   <= 32'd0;
      w_strb_q   <= 4'd0;
      rdata_q    <= 32'd0;
      for (ri = 0; ri < RFDC_REG_WORDS; ri = ri + 1) begin
        rfdc_regs[ri] <= 32'd0;
        rfdc_reg_written[ri] <= 1'b0;
      end
    end else begin
      if (aw_fire) begin
        aw_pending <= 1'b1;
        aw_addr_q  <= s_axi_awaddr;
      end
      if (w_fire) begin
        w_pending <= 1'b1;
        w_data_q  <= s_axi_wdata;
        w_strb_q  <= s_axi_wstrb;
      end
      if (bvalid_q && s_axi_bready)
        bvalid_q <= 1'b0;

      if (!bvalid_q && (aw_pending || aw_fire) && (w_pending || w_fire)) begin
        commit_addr = aw_fire ? s_axi_awaddr : aw_addr_q;
        commit_data = w_fire  ? s_axi_wdata  : w_data_q;
        commit_strb = w_fire  ? s_axi_wstrb  : w_strb_q;
        commit_word = rfdc_regs[commit_addr[15:2]];
        if (commit_strb[0]) commit_word[7:0]   = commit_data[7:0];
        if (commit_strb[1]) commit_word[15:8]  = commit_data[15:8];
        if (commit_strb[2]) commit_word[23:16] = commit_data[23:16];
        if (commit_strb[3]) commit_word[31:24] = commit_data[31:24];
        rfdc_regs[commit_addr[15:2]] <= commit_word;
        rfdc_reg_written[commit_addr[15:2]] <= 1'b1;
        aw_pending <= 1'b0;
        w_pending  <= 1'b0;
        bvalid_q   <= 1'b1;
      end

      if (s_axi_arvalid && s_axi_arready) begin
        rdata_q  <= rfdc_reg_read(s_axi_araddr);
        rvalid_q <= 1'b1;
      end else if (rvalid_q && s_axi_rready) begin
        rvalid_q <= 1'b0;
      end
    end
  end
  assign irq = 0;
  assign vout00_p = 0;
  assign vout00_n = 0;
  assign vout02_p = 0;
  assign vout02_n = 0;
  assign vout10_p = 0;
  assign vout10_n = 0;
  assign vout12_p = 0;
  assign vout12_n = 0;
  assign vout20_p = 0;
  assign vout20_n = 0;
  assign vout22_p = 0;
  assign vout22_n = 0;
  assign vout30_p = 0;
  assign vout30_n = 0;
  assign vout32_p = 0;
  assign vout32_n = 0;
  assign s00_axis_tready = sim_axis_ready;
  assign s01_axis_tready = sim_axis_ready;
  assign s02_axis_tready = sim_axis_ready;
  assign s03_axis_tready = sim_axis_ready;
  assign s10_axis_tready = sim_axis_ready;
  assign s11_axis_tready = sim_axis_ready;
  assign s12_axis_tready = sim_axis_ready;
  assign s13_axis_tready = sim_axis_ready;
  assign s20_axis_tready = sim_axis_ready;
  assign s21_axis_tready = sim_axis_ready;
  assign s22_axis_tready = sim_axis_ready;
  assign s23_axis_tready = sim_axis_ready;
  assign s30_axis_tready = sim_axis_ready;
  assign s31_axis_tready = sim_axis_ready;
  assign s32_axis_tready = sim_axis_ready;
  assign s33_axis_tready = sim_axis_ready;
  assign dac1_nco_update_busy = 0;
  assign dac2_nco_update_busy = 0;
  assign dac3_nco_update_busy = 0;

endmodule
