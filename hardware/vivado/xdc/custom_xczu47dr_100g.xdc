# 100G QSFP28 link constraints for the XCZU47DR RFSoC board.
#
# Pins extracted from 定制卡1原理图.pdf sheet 13 (BANK 128) and verified
# against the Vivado 2024.2 device database (PIN_FUNC values):
#   4-lane GTY quad X0Y4~X0Y7 (GTYE4_COMMON_X0Y1) = QSFP1
#   reference clock MGTREFCLK0_128 = 156.25 MHz crystal (XO32L-AGRL-156.25MHz)
#
# The ports terminate in GT primitives inside the CMAC IP.  The parent
# synthesis must not insert fabric I/O buffers around the preserved
# black box, otherwise the GT cannot bind to the package pins at link_design.

# ---- GT lane 0 ----
set_property PACKAGE_PIN Y35 [get_ports qsfp_txp[0]]
set_property PACKAGE_PIN Y36 [get_ports qsfp_txn[0]]
set_property PACKAGE_PIN AA38 [get_ports qsfp_rxp[0]]
set_property PACKAGE_PIN AA39 [get_ports qsfp_rxn[0]]
# ---- GT lane 1 ----
set_property PACKAGE_PIN V35 [get_ports qsfp_txp[1]]
set_property PACKAGE_PIN V36 [get_ports qsfp_txn[1]]
set_property PACKAGE_PIN W38 [get_ports qsfp_rxp[1]]
set_property PACKAGE_PIN W39 [get_ports qsfp_rxn[1]]
# ---- GT lane 2 ----
set_property PACKAGE_PIN T35 [get_ports qsfp_txp[2]]
set_property PACKAGE_PIN T36 [get_ports qsfp_txn[2]]
set_property PACKAGE_PIN U38 [get_ports qsfp_rxp[2]]
set_property PACKAGE_PIN U39 [get_ports qsfp_rxn[2]]
# ---- GT lane 3 ----
set_property PACKAGE_PIN R33 [get_ports qsfp_txp[3]]
set_property PACKAGE_PIN R34 [get_ports qsfp_txn[3]]
set_property PACKAGE_PIN R38 [get_ports qsfp_rxp[3]]
set_property PACKAGE_PIN R39 [get_ports qsfp_rxn[3]]

# ---- GT reference clock (156.25 MHz from the QSFP cage oscillator) ----
set_property PACKAGE_PIN AA33 [get_ports qsfp_refclk_p]
set_property PACKAGE_PIN AA34 [get_ports qsfp_refclk_n]
# No create_clock here: the CMAC IP's own OOC constraints already define the
# 156.25 MHz clock on qsfp_refclk_p.  A second create_clock on the same port
# would raise Constraints 18-1056 (clock override) and trip the release gate.

# All GT ports: no fabric buffers, no auto clock buffers
set_property IO_BUFFER_TYPE NONE [get_ports {qsfp_txp[*] qsfp_txn[*] qsfp_rxp[*] qsfp_rxn[*] qsfp_refclk_p qsfp_refclk_n}]
set_property CLOCK_BUFFER_TYPE NONE [get_ports {qsfp_txp[*] qsfp_txn[*] qsfp_rxp[*] qsfp_rxn[*] qsfp_refclk_p qsfp_refclk_n}]

# ---- QSFP28 cage control pins (BANK 87, VCCO=2.5V -> LVCMOS25) ----
# The bank 87 supply is 2.5 V (RST_88E1111/TRIG_1..3 use LVCMOS25 on the
# same bank).  QSFP28 module inputs are LVTTL (VIH=2.0 V), which the 2.5 V
# push-pull drive satisfies; the module-side 4.7K pullups to 3.3 V only
# carry ~170 uA and are harmless.
set_property PACKAGE_PIN C6 [get_ports qsfp_lpmode]
set_property IOSTANDARD LVCMOS25 [get_ports qsfp_lpmode]
set_property PACKAGE_PIN C5 [get_ports qsfp_resetn]
set_property IOSTANDARD LVCMOS25 [get_ports qsfp_resetn]

# The 100G UDP stack uses asynchronous FIFOs between the DDR/user clock
# domain and the CMAC TX/RX user clocks.  Constrain the pointer and handshake
# synchronizers as CDC paths so implementation is not forced to time unrelated
# clocks to near-zero phase alignments.  (Mirrors the retired 10G SFP+ CDC
# set; the instance hierarchy moved from udp_10g_i to udp_100g_i.)
set_false_path -to [get_pins -quiet -filter {REF_PIN_NAME =~ D} -of_objects [get_cells -quiet -hierarchical -regexp {.*udp_100g_i/core_inst/eth_mac_10g_fifo_inst/.*/fifo_inst/.*sync.*_reg_reg\[[0-9]+\]}]]
set_false_path -to [get_pins -quiet -filter {REF_PIN_NAME =~ D} -of_objects [get_cells -quiet -hierarchical -regexp {.*udp_100g_i/core_inst/eth_mac_10g_fifo_inst/.*/fifo_inst/.*sync.*_reg}]]

# The 512<->64 width adapter itself runs entirely in clk_axis (single clock);
# it has no internal CDC synchronizers and needs no false paths of its own.
