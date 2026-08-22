# Slave-only role constraints for the custom XCZU47DR synchronization link.

set_property PACKAGE_PIN C10 [get_ports dac_trigger_start]
set_property IOSTANDARD LVCMOS25 [get_ports dac_trigger_start]
set_property PACKAGE_PIN A6 [get_ports hmc7044_sync_test]
set_property IOSTANDARD LVCMOS25 [get_ports hmc7044_sync_test]

# A-Type-C differential SYNC input from the master card.
set_property PACKAGE_PIN AN8 [get_ports sync_1_tx_p]
set_property PACKAGE_PIN AN7 [get_ports sync_1_tx_n]
set_property IOSTANDARD DIFF_HSTL_I_12 [get_ports sync_1_tx_p]
set_property IOSTANDARD DIFF_HSTL_I_12 [get_ports sync_1_tx_n]
