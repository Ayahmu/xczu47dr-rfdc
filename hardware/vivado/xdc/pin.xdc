#set_property PACKAGE_PIN B12 [get_ports {GPIO_0_tri_o[1]}]
#set_property PACKAGE_PIN C11 [get_ports {GPIO_0_tri_o[0]}]
set_property PACKAGE_PIN G10 [get_ports {clk104_clk_spi_mux_sel_tri_o[0]}]
set_property PACKAGE_PIN H11 [get_ports {clk104_clk_spi_mux_sel_tri_o[1]}]
set_property IOSTANDARD LVCMOS18 [get_ports {clk104_clk_spi_mux_sel_tri_o[1]}]
set_property IOSTANDARD LVCMOS18 [get_ports {clk104_clk_spi_mux_sel_tri_o[0]}]
#set_property IOSTANDARD LVCMOS18 [get_ports {GPIO_0_tri_o[1]}]
#set_property IOSTANDARD LVCMOS18 [get_ports {GPIO_0_tri_o[0]}]

set_property PACKAGE_PIN C13 [get_ports {LED1[0]}]
set_property IOSTANDARD LVCMOS18 [get_ports {LED1[0]}]
set_property PACKAGE_PIN D14 [get_ports {LED0[0]}]
set_property IOSTANDARD LVCMOS18 [get_ports {LED0[0]}]
set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets clk]


# Trigger In (PMOD Pin 2 -> FPGA Input)
set_property PACKAGE_PIN G13      [get_ports trigger_in]
set_property IOSTANDARD LVCMOS18  [get_ports trigger_in]

# Trigger Out (FPGA Output -> PMOD Pin 1&3)
set_property PACKAGE_PIN G15      [get_ports trigger_out_loop]
set_property IOSTANDARD LVCMOS18  [get_ports trigger_out_loop]
set_property SLEW SLOW            [get_ports trigger_out_loop]
set_property DRIVE 4              [get_ports trigger_out_loop]

set_property PACKAGE_PIN G16      [get_ports trigger_out_sma]
set_property IOSTANDARD LVCMOS18  [get_ports trigger_out_sma]
set_property SLEW SLOW            [get_ports trigger_out_sma]
set_property DRIVE 4              [get_ports trigger_out_sma]

set_false_path -from [get_cells axigpio_i/ip/U0/gpio_core_1/Dual.gpio2_Data_Out_reg[*]]

set_clock_groups -asynchronous \
    -group [get_clocks clk_pl_0] \
    -group [get_clocks mmcm_clkout0] \
    -group [get_clocks RFDAC2_CLK]