# Minimal constraints for the custom XCZU47DR bring-up target.
# Source of truth: /home/kyu/workspace/定制卡1原理图.pdf, page 14 (RFSOC-B84-B87).
# Confirmed nets only: EXT_TRIGGER_P/N to FPGA U24 (XCZU47DR-2FFVG1517I), BANK84.

# EXT_TRIGGER_P -> IO_L11P_AD1P_84, package ball AR7; HD bank differential input
set_property PACKAGE_PIN AR7 [get_ports EXT_TRIGGER_P]
set_property IOSTANDARD DIFF_HSTL_I_18 [get_ports EXT_TRIGGER_P]

# EXT_TRIGGER_N -> IO_L11N_AD1N_84, package ball AR6; HD bank differential input
set_property PACKAGE_PIN AR6 [get_ports EXT_TRIGGER_N]
set_property IOSTANDARD DIFF_HSTL_I_18 [get_ports EXT_TRIGGER_N]

# First two-DAC bring-up intentionally exposes only DAC tile 2 slices 20/22.
# RFDC analog output pins use dedicated package wiring; no PACKAGE_PIN constraints
# are applied for vout20/vout22 here.

# HMC7044 clock chip control pins (SPI interface)
set_property PACKAGE_PIN E8 [get_ports RESET_H7044_H_0]
set_property IOSTANDARD LVCMOS25 [get_ports RESET_H7044_H_0]
set_property PACKAGE_PIN E9 [get_ports H7044_SYNC_0]
set_property IOSTANDARD LVCMOS25 [get_ports H7044_SYNC_0]
set_property PACKAGE_PIN E6 [get_ports H7044_SLEN_0]
set_property IOSTANDARD LVCMOS25 [get_ports H7044_SLEN_0]
set_property PACKAGE_PIN E7 [get_ports H7044_SCLK_0]
set_property IOSTANDARD LVCMOS25 [get_ports H7044_SCLK_0]
set_property PACKAGE_PIN F6 [get_ports H7044_SDATA_0]
set_property IOSTANDARD LVCMOS25 [get_ports H7044_SDATA_0]

# 88E1111 RESET/COMA net.  The schematic ties this active-low net to a
# 4.7K pull-up and 1uF reset capacitor; drive it high after PL configuration.
set_property PACKAGE_PIN A5 [get_ports RST_88E1111]
set_property IOSTANDARD LVCMOS25 [get_ports RST_88E1111]

# PL_CLK and PL_SYSREF from HMC7044 (differential LVDS)
set_property PACKAGE_PIN B10 [get_ports PL_CLK_P_0]
set_property IOSTANDARD LVDS_25 [get_ports PL_CLK_P_0]
set_property IOSTANDARD LVDS_25 [get_ports PL_CLK_N_0]
create_clock -name PL_CLK_P_0 -period 10 [get_ports PL_CLK_P_0]

set_property PACKAGE_PIN C8 [get_ports PL_SYSREF_P_0]
set_property IOSTANDARD LVDS_25 [get_ports PL_SYSREF_P_0]
set_property PACKAGE_PIN C7 [get_ports PL_SYSREF_N_0]
set_property IOSTANDARD LVDS_25 [get_ports PL_SYSREF_N_0]
set_property IOB false [get_ports PL_SYSREF_P_0]

# 10MHz external reference clock for HMC7044
set_property PACKAGE_PIN B8 [get_ports mclk_10m_p]
set_property IOSTANDARD LVDS_25 [get_ports mclk_10m_p]
set_property PACKAGE_PIN B7 [get_ports mclk_10m_n]
set_property IOSTANDARD LVDS_25 [get_ports mclk_10m_n]

# 10G SFP+ link copied from the known-good reference implementation report.
set_property PACKAGE_PIN N38 [get_ports sfp_rxp]
set_property PACKAGE_PIN N39 [get_ports sfp_rxn]
set_property PACKAGE_PIN P35 [get_ports sfp_txp]
set_property PACKAGE_PIN P36 [get_ports sfp_txn]
set_property PACKAGE_PIN W33 [get_ports sfp_refclkp]
set_property PACKAGE_PIN W34 [get_ports sfp_refclkn]
set_property PACKAGE_PIN AK19 [get_ports SFP_TX_DIS]
set_property IOSTANDARD LVCMOS12 [get_ports SFP_TX_DIS]

# The imported 10G UDP MAC uses asynchronous FIFOs between the DDR/user clock
# and XXV Ethernet TX/RX clocks.  Constrain the pointer and handshake
# synchronizers as CDC paths so implementation is not forced to time unrelated
# clocks to near-zero phase alignments.
set_false_path -to [get_pins -quiet -filter {REF_PIN_NAME =~ D} -of_objects [get_cells -quiet -hierarchical -regexp {.*udp_10g_i/core_inst/eth_mac_10g_fifo_inst/.*/fifo_inst/.*sync.*_reg_reg\[[0-9]+\]}]]
set_false_path -to [get_pins -quiet -filter {REF_PIN_NAME =~ D} -of_objects [get_cells -quiet -hierarchical -regexp {.*udp_10g_i/core_inst/eth_mac_10g_fifo_inst/.*/fifo_inst/.*sync.*_reg}]]
set_false_path -to [get_pins -quiet -filter {REF_PIN_NAME =~ D} -of_objects [get_cells -quiet -hierarchical -regexp {.*udp_10g_i/i_xxv_ethernet_0_axi4_lite_user_if/.*cdc_sync.*}]]

# PS GPIO trigger is synchronized into DDR and DAC fabric domains in Top.v.
# Only the first synchronizer stage is asynchronous; downstream stages remain timed.
set_false_path -quiet -to [get_pins -quiet top_i/trigger_ddr_sync_ff_reg[0]/D]
set_false_path -quiet -to [get_pins -quiet top_i/trigger_dac_sync_ff_reg[0]/D]

# Single-DDR bring-up constraints adapted from the user-provided XCZU47DR
# reference project MIG implementation. The custom card uses a 64-bit C0 DDR4
# interface matching MT40A1G16RC-062E and the reference x64/AXI512 design.
set_property PACKAGE_PIN AN11 [get_ports c0_sys_clk_p]
set_property PACKAGE_PIN AP11 [get_ports c0_sys_clk_n]
set_property PACKAGE_PIN AR9 [get_ports c0_ddr4_act_n]
set_property PACKAGE_PIN AN13 [get_ports c0_ddr4_reset_n]
set_property PACKAGE_PIN AV10 [get_ports {c0_ddr4_adr[0]}]
set_property PACKAGE_PIN AW10 [get_ports {c0_ddr4_adr[1]}]
set_property PACKAGE_PIN AU12 [get_ports {c0_ddr4_adr[2]}]
set_property PACKAGE_PIN AP10 [get_ports {c0_ddr4_adr[3]}]
set_property PACKAGE_PIN AV11 [get_ports {c0_ddr4_adr[4]}]
set_property PACKAGE_PIN AW11 [get_ports {c0_ddr4_adr[5]}]
set_property PACKAGE_PIN AM13 [get_ports {c0_ddr4_adr[6]}]
set_property PACKAGE_PIN AW8 [get_ports {c0_ddr4_adr[7]}]
set_property PACKAGE_PIN AT10 [get_ports {c0_ddr4_adr[8]}]
set_property PACKAGE_PIN AW9 [get_ports {c0_ddr4_adr[9]}]
set_property PACKAGE_PIN AM12 [get_ports {c0_ddr4_adr[10]}]
set_property PACKAGE_PIN AN12 [get_ports {c0_ddr4_adr[11]}]
set_property PACKAGE_PIN AN10 [get_ports {c0_ddr4_adr[12]}]
set_property PACKAGE_PIN AR11 [get_ports {c0_ddr4_adr[13]}]
set_property PACKAGE_PIN AU10 [get_ports {c0_ddr4_adr[14]}]
set_property PACKAGE_PIN AM10 [get_ports {c0_ddr4_adr[15]}]
set_property PACKAGE_PIN AL10 [get_ports {c0_ddr4_adr[16]}]
set_property PACKAGE_PIN AR12 [get_ports {c0_ddr4_ba[0]}]
set_property PACKAGE_PIN AM8 [get_ports {c0_ddr4_ba[1]}]
set_property PACKAGE_PIN AV12 [get_ports {c0_ddr4_bg[0]}]
set_property PACKAGE_PIN AT12 [get_ports {c0_ddr4_ck_t[0]}]
set_property PACKAGE_PIN AT11 [get_ports {c0_ddr4_ck_c[0]}]
set_property PACKAGE_PIN AR8 [get_ports {c0_ddr4_cke[0]}]
set_property PACKAGE_PIN AP8 [get_ports {c0_ddr4_cs_n[0]}]
set_property PACKAGE_PIN AP9 [get_ports {c0_ddr4_odt[0]}]
set_property PACKAGE_PIN AW14 [get_ports {c0_ddr4_dm_n[0]}]
set_property PACKAGE_PIN AP13 [get_ports {c0_ddr4_dm_n[1]}]
set_property PACKAGE_PIN AL16 [get_ports {c0_ddr4_dm_n[2]}]
set_property PACKAGE_PIN AK13 [get_ports {c0_ddr4_dm_n[3]}]
set_property PACKAGE_PIN AW19 [get_ports {c0_ddr4_dm_n[4]}]
set_property PACKAGE_PIN AR17 [get_ports {c0_ddr4_dm_n[5]}]
set_property PACKAGE_PIN AM20 [get_ports {c0_ddr4_dm_n[6]}]
set_property PACKAGE_PIN AJ18 [get_ports {c0_ddr4_dm_n[7]}]
set_property PACKAGE_PIN AV16 [get_ports {c0_ddr4_dqs_t[0]}]
set_property PACKAGE_PIN AN17 [get_ports {c0_ddr4_dqs_t[1]}]
set_property PACKAGE_PIN AG17 [get_ports {c0_ddr4_dqs_t[2]}]
set_property PACKAGE_PIN AJ14 [get_ports {c0_ddr4_dqs_t[3]}]
set_property PACKAGE_PIN AV21 [get_ports {c0_ddr4_dqs_t[4]}]
set_property PACKAGE_PIN AR22 [get_ports {c0_ddr4_dqs_t[5]}]
set_property PACKAGE_PIN AL22 [get_ports {c0_ddr4_dqs_t[6]}]
set_property PACKAGE_PIN AG20 [get_ports {c0_ddr4_dqs_t[7]}]
set_property PACKAGE_PIN AW16 [get_ports {c0_ddr4_dqs_c[0]}]
set_property PACKAGE_PIN AN16 [get_ports {c0_ddr4_dqs_c[1]}]
set_property PACKAGE_PIN AH17 [get_ports {c0_ddr4_dqs_c[2]}]
set_property PACKAGE_PIN AK14 [get_ports {c0_ddr4_dqs_c[3]}]
set_property PACKAGE_PIN AW21 [get_ports {c0_ddr4_dqs_c[4]}]
set_property PACKAGE_PIN AT22 [get_ports {c0_ddr4_dqs_c[5]}]
set_property PACKAGE_PIN AM22 [get_ports {c0_ddr4_dqs_c[6]}]
set_property PACKAGE_PIN AH20 [get_ports {c0_ddr4_dqs_c[7]}]
set_property PACKAGE_PIN AV15 [get_ports {c0_ddr4_dq[0]}]
set_property PACKAGE_PIN AW15 [get_ports {c0_ddr4_dq[1]}]
set_property PACKAGE_PIN AU13 [get_ports {c0_ddr4_dq[2]}]
set_property PACKAGE_PIN AV13 [get_ports {c0_ddr4_dq[3]}]
set_property PACKAGE_PIN AT16 [get_ports {c0_ddr4_dq[4]}]
set_property PACKAGE_PIN AT15 [get_ports {c0_ddr4_dq[5]}]
set_property PACKAGE_PIN AU15 [get_ports {c0_ddr4_dq[6]}]
set_property PACKAGE_PIN AU14 [get_ports {c0_ddr4_dq[7]}]
set_property PACKAGE_PIN AP16 [get_ports {c0_ddr4_dq[8]}]
set_property PACKAGE_PIN AR16 [get_ports {c0_ddr4_dq[9]}]
set_property PACKAGE_PIN AP14 [get_ports {c0_ddr4_dq[10]}]
set_property PACKAGE_PIN AR14 [get_ports {c0_ddr4_dq[11]}]
set_property PACKAGE_PIN AM15 [get_ports {c0_ddr4_dq[12]}]
set_property PACKAGE_PIN AN15 [get_ports {c0_ddr4_dq[13]}]
set_property PACKAGE_PIN AL17 [get_ports {c0_ddr4_dq[14]}]
set_property PACKAGE_PIN AM17 [get_ports {c0_ddr4_dq[15]}]
set_property PACKAGE_PIN AK17 [get_ports {c0_ddr4_dq[16]}]
set_property PACKAGE_PIN AK16 [get_ports {c0_ddr4_dq[17]}]
set_property PACKAGE_PIN AJ16 [get_ports {c0_ddr4_dq[18]}]
set_property PACKAGE_PIN AJ15 [get_ports {c0_ddr4_dq[19]}]
set_property PACKAGE_PIN AH16 [get_ports {c0_ddr4_dq[20]}]
set_property PACKAGE_PIN AH15 [get_ports {c0_ddr4_dq[21]}]
set_property PACKAGE_PIN AF17 [get_ports {c0_ddr4_dq[22]}]
set_property PACKAGE_PIN AF16 [get_ports {c0_ddr4_dq[23]}]
set_property PACKAGE_PIN AL14 [get_ports {c0_ddr4_dq[24]}]
set_property PACKAGE_PIN AM14 [get_ports {c0_ddr4_dq[25]}]
set_property PACKAGE_PIN AJ12 [get_ports {c0_ddr4_dq[26]}]
set_property PACKAGE_PIN AK12 [get_ports {c0_ddr4_dq[27]}]
set_property PACKAGE_PIN AG12 [get_ports {c0_ddr4_dq[28]}]
set_property PACKAGE_PIN AH12 [get_ports {c0_ddr4_dq[29]}]
set_property PACKAGE_PIN AH13 [get_ports {c0_ddr4_dq[30]}]
set_property PACKAGE_PIN AJ13 [get_ports {c0_ddr4_dq[31]}]
set_property PACKAGE_PIN AV20 [get_ports {c0_ddr4_dq[32]}]
set_property PACKAGE_PIN AW20 [get_ports {c0_ddr4_dq[33]}]
set_property PACKAGE_PIN AU17 [get_ports {c0_ddr4_dq[34]}]
set_property PACKAGE_PIN AV17 [get_ports {c0_ddr4_dq[35]}]
set_property PACKAGE_PIN AU18 [get_ports {c0_ddr4_dq[36]}]
set_property PACKAGE_PIN AV18 [get_ports {c0_ddr4_dq[37]}]
set_property PACKAGE_PIN AU20 [get_ports {c0_ddr4_dq[38]}]
set_property PACKAGE_PIN AU19 [get_ports {c0_ddr4_dq[39]}]
set_property PACKAGE_PIN AR21 [get_ports {c0_ddr4_dq[40]}]
set_property PACKAGE_PIN AT21 [get_ports {c0_ddr4_dq[41]}]
set_property PACKAGE_PIN AR19 [get_ports {c0_ddr4_dq[42]}]
set_property PACKAGE_PIN AT19 [get_ports {c0_ddr4_dq[43]}]
set_property PACKAGE_PIN AP18 [get_ports {c0_ddr4_dq[44]}]
set_property PACKAGE_PIN AR18 [get_ports {c0_ddr4_dq[45]}]
set_property PACKAGE_PIN AP20 [get_ports {c0_ddr4_dq[46]}]
set_property PACKAGE_PIN AP19 [get_ports {c0_ddr4_dq[47]}]
set_property PACKAGE_PIN AN21 [get_ports {c0_ddr4_dq[48]}]
set_property PACKAGE_PIN AP21 [get_ports {c0_ddr4_dq[49]}]
set_property PACKAGE_PIN AM18 [get_ports {c0_ddr4_dq[50]}]
set_property PACKAGE_PIN AN18 [get_ports {c0_ddr4_dq[51]}]
set_property PACKAGE_PIN AL19 [get_ports {c0_ddr4_dq[52]}]
set_property PACKAGE_PIN AM19 [get_ports {c0_ddr4_dq[53]}]
set_property PACKAGE_PIN AL21 [get_ports {c0_ddr4_dq[54]}]
set_property PACKAGE_PIN AL20 [get_ports {c0_ddr4_dq[55]}]
set_property PACKAGE_PIN AK22 [get_ports {c0_ddr4_dq[56]}]
set_property PACKAGE_PIN AK21 [get_ports {c0_ddr4_dq[57]}]
set_property PACKAGE_PIN AJ20 [get_ports {c0_ddr4_dq[58]}]
set_property PACKAGE_PIN AJ19 [get_ports {c0_ddr4_dq[59]}]
set_property PACKAGE_PIN AG18 [get_ports {c0_ddr4_dq[60]}]
set_property PACKAGE_PIN AH18 [get_ports {c0_ddr4_dq[61]}]
set_property PACKAGE_PIN AF20 [get_ports {c0_ddr4_dq[62]}]
set_property PACKAGE_PIN AF19 [get_ports {c0_ddr4_dq[63]}]


# The PS PL clock, DDR UI clock, and RFDC DAC fabric clock are independent
# domains. Match the original ZCU216 timing intent for the custom target so
# async FIFO/CDC crossings are not timed as synchronous paths.
set_clock_groups -quiet -asynchronous \
    -group [get_clocks -quiet clk_pl_0] \
    -group [get_clocks -quiet mmcm_clkout0] \
    -group [get_clocks -quiet {RFDAC2_CLK clk_out1_design_1_clk_wiz_dac_axis_0_0}]
