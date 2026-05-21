module TopCustomXczu47dr (
    input  EXT_TRIGGER_P,
    input  EXT_TRIGGER_N,

    // HMC7044 clock chip control (SPI interface)
    output RESET_H7044_H_0,
    output H7044_SYNC_0,
    output H7044_SLEN_0,
    output H7044_SCLK_0,
    output H7044_SDATA_0,

    output RST_88E1111,

    // PL_CLK and PL_SYSREF from HMC7044 (differential LVDS, 100 MHz)
    input  PL_CLK_P_0,
    input  PL_CLK_N_0,
    input  PL_SYSREF_P_0,
    input  PL_SYSREF_N_0,

    // 10MHz external reference clock for HMC7044 (differential)
    input  mclk_10m_p,
    input  mclk_10m_n,

    // 10G SFP+ UDP link, matching the reference project.
    input  sfp_refclkp,
    input  sfp_refclkn,
    input  sfp_rxp,
    input  sfp_rxn,
    output sfp_txp,
    output sfp_txn,
    output SFP_TX_DIS,

    input  dac2_clk_clk_n,
    input  dac2_clk_clk_p,
    input  sysref_in_diff_n,
    input  sysref_in_diff_p,

    output vout20_v_n,
    output vout20_v_p,
    output vout22_v_n,
    output vout22_v_p,

    input           c0_sys_clk_n,
    input           c0_sys_clk_p,
    output          c0_ddr4_act_n,
    output [16:0]   c0_ddr4_adr,
    output [1:0]    c0_ddr4_ba,
    output [0:0]    c0_ddr4_bg,
    output [0:0]    c0_ddr4_ck_c,
    output [0:0]    c0_ddr4_ck_t,
    output [0:0]    c0_ddr4_cke,
`ifdef CUSTOM_XCZU47DR
    output [0:0]    c0_ddr4_cs_n,
    inout  [7:0]    c0_ddr4_dm_n,
    inout  [63:0]   c0_ddr4_dq,
    inout  [7:0]    c0_ddr4_dqs_c,
    inout  [7:0]    c0_ddr4_dqs_t,
`else
    output [1:0]    c0_ddr4_cs_n,
    inout  [3:0]    c0_ddr4_dm_n,
    inout  [31:0]   c0_ddr4_dq,
    inout  [3:0]    c0_ddr4_dqs_c,
    inout  [3:0]    c0_ddr4_dqs_t,
`endif
    output [0:0]    c0_ddr4_odt,
    output          c0_ddr4_reset_n
);

  wire       trigger_in_single_ended;

  assign RST_88E1111 = 1'b1;

  IBUFDS #(
      .DIFF_TERM("FALSE"),
      .IBUF_LOW_PWR("TRUE"),
      .IOSTANDARD("LVDS")
  ) ext_trigger_ibufds_i (
      .I(EXT_TRIGGER_P),
      .IB(EXT_TRIGGER_N),
      .O(trigger_in_single_ended)
  );

  Top top_i (
      .trigger_in(trigger_in_single_ended),
      
      // HMC7044 control ports
      .RESET_H7044_H_0(RESET_H7044_H_0),
      .H7044_SYNC_0(H7044_SYNC_0),
      .H7044_SLEN_0(H7044_SLEN_0),
      .H7044_SCLK_0(H7044_SCLK_0),
      .H7044_SDATA_0(H7044_SDATA_0),
      
      // PL_CLK and PL_SYSREF
      .PL_CLK_P_0(PL_CLK_P_0),
      .PL_CLK_N_0(PL_CLK_N_0),
      .PL_SYSREF_P_0(PL_SYSREF_P_0),
      .PL_SYSREF_N_0(PL_SYSREF_N_0),
      
      // 10MHz reference clock
      .mclk_10m_p(mclk_10m_p),
      .mclk_10m_n(mclk_10m_n),

      // 10G SFP+ UDP link
      .sfp_refclkp(sfp_refclkp),
      .sfp_refclkn(sfp_refclkn),
      .sfp_rxp(sfp_rxp),
      .sfp_rxn(sfp_rxn),
      .sfp_txp(sfp_txp),
      .sfp_txn(sfp_txn),
      .SFP_TX_DIS(SFP_TX_DIS),
      
      .dac2_clk_clk_n(dac2_clk_clk_n),
      .dac2_clk_clk_p(dac2_clk_clk_p),
      .sysref_in_diff_n(sysref_in_diff_n),
      .sysref_in_diff_p(sysref_in_diff_p),
      .vout20_v_n(vout20_v_n),
      .vout20_v_p(vout20_v_p),
      .vout22_v_n(vout22_v_n),
      .vout22_v_p(vout22_v_p),
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
