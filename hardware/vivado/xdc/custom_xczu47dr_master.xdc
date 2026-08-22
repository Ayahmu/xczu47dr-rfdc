# Master-only role constraints for the custom XCZU47DR synchronization link.

set_property PACKAGE_PIN D9 [get_ports FPGA_CLK1_P]
set_property PACKAGE_PIN D8 [get_ports FPGA_CLK1_N]
set_property IOSTANDARD LVDS_25 [get_ports FPGA_CLK1_P]
set_property IOSTANDARD LVDS_25 [get_ports FPGA_CLK1_N]
create_clock -name FPGA_CLK1 -period 10.000 [get_ports FPGA_CLK1_P]

set_property PACKAGE_PIN C10 [get_ports PL_SYSREF_out]
set_property IOSTANDARD LVCMOS25 [get_ports PL_SYSREF_out]
set_property PACKAGE_PIN A6 [get_ports FPGA_CLK1_P_O]
set_property IOSTANDARD LVCMOS25 [get_ports FPGA_CLK1_P_O]

# Type-C differential SYNC output to the slave card.
set_property PACKAGE_PIN AN8 [get_ports sync_1_tx_p]
set_property PACKAGE_PIN AN7 [get_ports sync_1_tx_n]
set_property IOSTANDARD DIFF_HSTL_I_12 [get_ports sync_1_tx_p]
set_property IOSTANDARD DIFF_HSTL_I_12 [get_ports sync_1_tx_n]
set_property SLEW MEDIUM [get_ports sync_1_tx_p]
set_property SLEW MEDIUM [get_ports sync_1_tx_n]
