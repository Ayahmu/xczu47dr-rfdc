module TopCustomXczu47dr #(
    // External XS17 reference frequency in MHz (250 or 10).
    parameter integer REFERENCE_MHZ = 250
) (
    // HMC7044 clock chip control (SPI interface)
    output RESET_H7044_H_0,
    output H7044_SYNC_0,
    output H7044_SLEN_0,
    output H7044_SCLK_0,
    output H7044_SDATA_0,

    output RST_88E1111,
    // XS18: first-sample marker output.  XS19: external playback Trigger input.
    output TRIG_1,
    input  TRIG_2,

    // PL_SYSREF from HMC7044 (differential LVDS)
    input  PL_SYSREF_P_0,
    input  PL_SYSREF_N_0,

    // 100G QSFP28 UDP link (CMAC CAUI-4, RS-FEC).
    input  qsfp_refclk_p,
    input  qsfp_refclk_n,
    input  [3:0] qsfp_rxp,
    input  [3:0] qsfp_rxn,
    output [3:0] qsfp_txp,
    output [3:0] qsfp_txn,
    output qsfp_lpmode,
    output qsfp_resetn,

    input  dac2_clk_clk_n,
    input  dac2_clk_clk_p,
    input  sysref_in_diff_n,
    input  sysref_in_diff_p,

    output vout00_v_n,
    output vout00_v_p,
    output vout02_v_n,
    output vout02_v_p,
    output vout10_v_n,
    output vout10_v_p,
    output vout12_v_n,
    output vout12_v_p,
    output vout20_v_n,
    output vout20_v_p,
    output vout22_v_n,
    output vout22_v_p,
    output vout30_v_n,
    output vout30_v_p,
    output vout32_v_n,
    output vout32_v_p,

    input           c0_sys_clk_n,
    input           c0_sys_clk_p,
    output          c0_ddr4_act_n,
    output [16:0]   c0_ddr4_adr,
    output [1:0]    c0_ddr4_ba,
    output [0:0]    c0_ddr4_bg,
    output [0:0]    c0_ddr4_ck_c,
    output [0:0]    c0_ddr4_ck_t,
    output [0:0]    c0_ddr4_cke,
    output [0:0]    c0_ddr4_cs_n,
    inout  [7:0]    c0_ddr4_dm_n,
    inout  [63:0]   c0_ddr4_dq,
    inout  [7:0]    c0_ddr4_dqs_c,
    inout  [7:0]    c0_ddr4_dqs_t,
    output [0:0]    c0_ddr4_odt,
    output          c0_ddr4_reset_n
);

  assign RST_88E1111 = 1'b1;


  Top #(
      .REFERENCE_MHZ(REFERENCE_MHZ)
  ) top_i (
      .TRIG_1(TRIG_1),
      .TRIG_2(TRIG_2),

      // HMC7044 control ports
      .RESET_H7044_H_0(RESET_H7044_H_0),
      .H7044_SYNC_0(H7044_SYNC_0),
      .H7044_SLEN_0(H7044_SLEN_0),
      .H7044_SCLK_0(H7044_SCLK_0),
      .H7044_SDATA_0(H7044_SDATA_0),
      
      // PL_SYSREF
      .PL_SYSREF_P_0(PL_SYSREF_P_0),
      .PL_SYSREF_N_0(PL_SYSREF_N_0),

      // 100G QSFP28 UDP link
      .qsfp_refclk_p(qsfp_refclk_p),
      .qsfp_refclk_n(qsfp_refclk_n),
      .qsfp_rxp(qsfp_rxp),
      .qsfp_rxn(qsfp_rxn),
      .qsfp_txp(qsfp_txp),
      .qsfp_txn(qsfp_txn),
      .qsfp_lpmode(qsfp_lpmode),
      .qsfp_resetn(qsfp_resetn),
      
      .dac2_clk_clk_n(dac2_clk_clk_n),
      .dac2_clk_clk_p(dac2_clk_clk_p),
      .sysref_in_diff_n(sysref_in_diff_n),
      .sysref_in_diff_p(sysref_in_diff_p),
      .vout00_v_n(vout00_v_n),
      .vout00_v_p(vout00_v_p),
      .vout02_v_n(vout02_v_n),
      .vout02_v_p(vout02_v_p),
      .vout10_v_n(vout10_v_n),
      .vout10_v_p(vout10_v_p),
      .vout12_v_n(vout12_v_n),
      .vout12_v_p(vout12_v_p),
      .vout20_v_n(vout20_v_n),
      .vout20_v_p(vout20_v_p),
      .vout22_v_n(vout22_v_n),
      .vout22_v_p(vout22_v_p),
      .vout30_v_n(vout30_v_n),
      .vout30_v_p(vout30_v_p),
      .vout32_v_n(vout32_v_n),
      .vout32_v_p(vout32_v_p),
      .c0_sys_clk_n(c0_sys_clk_n),
      .c0_sys_clk_p(c0_sys_clk_p),
      .c0_ddr4_act_n(c0_ddr4_act_n),
      .c0_ddr4_adr(c0_ddr4_adr),
      .c0_ddr4_ba(c0_ddr4_ba),
      .c0_ddr4_bg(c0_ddr4_bg),
      .c0_ddr4_ck_c(c0_ddr4_ck_c),
      .c0_ddr4_ck_t(c0_ddr4_ck_t),
      .c0_ddr4_cke(c0_ddr4_cke),
      .c0_ddr4_cs_n(c0_ddr4_cs_n),
      .c0_ddr4_dm_n(c0_ddr4_dm_n),
      .c0_ddr4_dq(c0_ddr4_dq),
      .c0_ddr4_dqs_c(c0_ddr4_dqs_c),
      .c0_ddr4_dqs_t(c0_ddr4_dqs_t),
      .c0_ddr4_odt(c0_ddr4_odt),
      .c0_ddr4_reset_n(c0_ddr4_reset_n)
  );

endmodule
