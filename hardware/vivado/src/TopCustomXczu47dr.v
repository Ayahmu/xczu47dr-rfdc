module TopCustomXczu47dr #(
    parameter integer IS_MASTER = 1
) (
    // HMC7044 clock chip control (SPI interface)
    output RESET_H7044_H_0,
    output H7044_SYNC_0,
    output H7044_SLEN_0,
    output H7044_SCLK_0,
    output H7044_SDATA_0,

    output RST_88E1111,
    output TRIG_1,

`ifdef CUSTOM_XCZU47DR_SLAVE
    // Slave-only physical pins.
    output hmc7044_sync_test,
    // The slave now uses the board's A connector as the SYNC input.
    // Keep the internal Top.v signal named sync_3_tx for compatibility.
    input  sync_1_tx_p,
    input  sync_1_tx_n,
    input  dac_trigger_start,
`else
    // Master-only physical pins.
    output sync_1_tx_p,
    output sync_1_tx_n,
    output PL_SYSREF_out,
    input  FPGA_CLK1_P,
    input  FPGA_CLK1_N,
    output FPGA_CLK1_P_O,
`endif

    // PL_CLK and PL_SYSREF from HMC7044 (differential LVDS, 100 MHz)
    input  PL_CLK_P_0,
    input  PL_CLK_N_0,
    input  PL_SYSREF_P_0,
    input  PL_SYSREF_N_0,

    // HMC7044-generated 10 MHz monitor clock returned to the FPGA.
    input  mclk_10m_p,
    input  mclk_10m_n,
    input  EXT_TRIGGER_P,
    input  EXT_TRIGGER_N,

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

  wire trig_2_unused;
  wire trig_3_unused;

`ifdef CUSTOM_XCZU47DR_SLAVE
  wire sync_1_tx_p_unused;
  wire sync_1_tx_n_unused;
  wire pl_sysref_out_unused;
  wire role_sync_3_tx_p = sync_1_tx_p;
  wire role_sync_3_tx_n = sync_1_tx_n;
  wire role_dac_trigger_start = dac_trigger_start;

  assign hmc7044_sync_test = H7044_SYNC_0;
`else
  generate
    if (IS_MASTER) begin : gen_master_fpga_clk
      wire fpga_clk1_ibuf;
      wire fpga_clk1_bufg;

      IBUFDS #(
          .DIFF_TERM("FALSE"),
          .IBUF_LOW_PWR("FALSE")
      ) FPGA_CLK1_IBUFDS_inst (
          .I  (FPGA_CLK1_P),
          .IB (FPGA_CLK1_N),
          .O  (fpga_clk1_ibuf)
      );

      BUFGCE FPGA_CLK1_BUFG_inst (
          .I  (fpga_clk1_ibuf),
          .CE (1'b1),
          .O  (fpga_clk1_bufg)
      );

      ODDRE1 #(
          .IS_C_INVERTED(1'b0),
          .SRVAL(1'b0)
      ) FPGA_CLK1_P_ODDR_inst (
          .Q  (FPGA_CLK1_P_O),
          .C  (fpga_clk1_bufg),
          .D1 (1'b1),
          .D2 (1'b0),
          .SR (1'b0)
      );
    end
  endgenerate

  wire role_sync_3_tx_p = 1'b0;
  wire role_sync_3_tx_n = 1'b0;
  wire role_dac_trigger_start = 1'b0;
`endif

  Top #(
      .IS_MASTER(IS_MASTER)
  ) top_i (
      .TRIG_1(TRIG_1),
      .TRIG_2(trig_2_unused),
      .TRIG_3(trig_3_unused),
`ifdef CUSTOM_XCZU47DR_SLAVE
      .sync_1_tx_p(sync_1_tx_p_unused),
      .sync_1_tx_n(sync_1_tx_n_unused),
      .PL_SYSREF_out(pl_sysref_out_unused),
`else
      .sync_1_tx_p(sync_1_tx_p),
      .sync_1_tx_n(sync_1_tx_n),
      .PL_SYSREF_out(PL_SYSREF_out),
`endif
      .sync_3_tx_p(role_sync_3_tx_p),
      .sync_3_tx_n(role_sync_3_tx_n),
      .dac_trigger_start(role_dac_trigger_start),

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
      
      // HMC7044 10 MHz monitor clock
      .mclk_10m_p(mclk_10m_p),
      .mclk_10m_n(mclk_10m_n),
      .EXT_TRIGGER_P(EXT_TRIGGER_P),
      .EXT_TRIGGER_N(EXT_TRIGGER_N),

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
