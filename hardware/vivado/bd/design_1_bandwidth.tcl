set scripts_vivado_version 2024.2
set current_vivado_version [version -short]
if {[string first $scripts_vivado_version $current_vivado_version] == -1} {
  puts "ERROR: This script expects Vivado ${scripts_vivado_version}; running ${current_vivado_version}"
  return 1
}

namespace eval _tcl {
proc get_script_folder {} {
   return [file dirname [file normalize [info script]]]
}
}
set script_folder [_tcl::get_script_folder]
if {![llength [info commands target_config_get]]} {
   source [file normalize "${script_folder}/../scripts/target_config.tcl"]
}
if {![info exists target]} {
   set target "custom_xczu47dr"
}

set design_name design_1
create_bd_design $design_name
current_bd_design $design_name

set M_AXI_CTRL [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_CTRL]
set_property -dict [list CONFIG.ADDR_WIDTH {32} CONFIG.DATA_WIDTH {32} CONFIG.PROTOCOL {AXI4LITE} CONFIG.READ_WRITE_MODE {READ_WRITE}] $M_AXI_CTRL

set M_AXI_INST [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_INST]
set_property -dict [list CONFIG.ADDR_WIDTH {32} CONFIG.DATA_WIDTH {32} CONFIG.PROTOCOL {AXI4} CONFIG.READ_WRITE_MODE {READ_WRITE}] $M_AXI_INST

set M_AXI_PS_DDR [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_PS_DDR]
set_property -dict [list \
  CONFIG.ADDR_WIDTH {40} \
  CONFIG.ARUSER_WIDTH {16} \
  CONFIG.AWUSER_WIDTH {16} \
  CONFIG.DATA_WIDTH {128} \
  CONFIG.HAS_BRESP {1} \
  CONFIG.HAS_BURST {1} \
  CONFIG.HAS_CACHE {1} \
  CONFIG.HAS_LOCK {1} \
  CONFIG.HAS_PROT {1} \
  CONFIG.HAS_QOS {1} \
  CONFIG.HAS_RRESP {1} \
  CONFIG.HAS_WSTRB {1} \
  CONFIG.ID_WIDTH {16} \
  CONFIG.PROTOCOL {AXI4} \
  CONFIG.READ_WRITE_MODE {READ_WRITE}] $M_AXI_PS_DDR

set pl_clk [create_bd_port -dir O -type clk pl_clk]
set_property -dict [list CONFIG.ASSOCIATED_BUSIF {M_AXI_CTRL:M_AXI_INST} CONFIG.ASSOCIATED_RESET {pl_aresetn}] $pl_clk
set pl_aresetn [create_bd_port -dir I -from 0 -to 0 -type rst pl_aresetn]
set ddr4_ui_clk [create_bd_port -dir I -type clk ddr4_ui_clk]
set_property -dict [list CONFIG.ASSOCIATED_BUSIF {M_AXI_PS_DDR} CONFIG.ASSOCIATED_RESET {pl_aresetn}] $ddr4_ui_clk
set pl_resetn0 [create_bd_port -dir O -from 0 -to 0 -type rst pl_resetn0]

set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 zynq_ultra_ps_e_0]
set_property -dict [list \
  CONFIG.PSU__PSS_REF_CLK__FREQMHZ {33.333} \
  CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__USE__M_AXI_GP1 {1} \
  CONFIG.PSU__USE__M_AXI_GP2 {0} \
  CONFIG.PSU__USE__S_AXI_GP2 {0} \
  CONFIG.PSU__USE__S_AXI_GP3 {0} \
  CONFIG.PSU__MAXIGP0__DATA_WIDTH {128} \
  CONFIG.PSU__MAXIGP1__DATA_WIDTH {128} \
  CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
  CONFIG.PSU__PL_CLK0_BUF {TRUE} \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} \
  CONFIG.PSU__UART0__PERIPHERAL__ENABLE {1} \
  CONFIG.PSU__UART0__PERIPHERAL__IO {MIO 42 .. 43} \
  CONFIG.PSU__UART0__BAUD_RATE {115200} \
  CONFIG.PSU__QSPI__PERIPHERAL__ENABLE {1} \
  CONFIG.PSU__QSPI__PERIPHERAL__IO {MIO 0 .. 12} \
  CONFIG.PSU__QSPI__PERIPHERAL__DATA_MODE {x4} \
  CONFIG.PSU__QSPI__PERIPHERAL__MODE {Dual Parallel} \
  CONFIG.PSU__SD0__PERIPHERAL__ENABLE {1} \
  CONFIG.PSU__SD0__PERIPHERAL__IO {MIO 13 .. 16 21 22} \
  CONFIG.PSU__SD0__DATA_TRANSFER_MODE {4Bit} \
  CONFIG.PSU__SD0__SLOT_TYPE {eMMC} \
  CONFIG.PSU__SD1__PERIPHERAL__ENABLE {1} \
  CONFIG.PSU__SD1__PERIPHERAL__IO {MIO 46 .. 51} \
  CONFIG.PSU__SD1__DATA_TRANSFER_MODE {4Bit} \
  CONFIG.PSU__SD1__SLOT_TYPE {SD 2.0} \
  CONFIG.PSU__SD1__GRP_CD__ENABLE {1} \
  CONFIG.PSU__SD1__GRP_CD__IO {MIO 45} \
  CONFIG.PSU__ENET3__PERIPHERAL__ENABLE {1} \
  CONFIG.PSU__ENET3__PERIPHERAL__IO {MIO 64 .. 75} \
  CONFIG.PSU__ENET3__GRP_MDIO__ENABLE {1} \
  CONFIG.PSU__ENET3__GRP_MDIO__IO {MIO 76 .. 77} \
  CONFIG.PSU__DDRC__COMPONENTS {Components} \
  CONFIG.PSU__DDRC__DDR4_ADDR_MAPPING {1} \
  CONFIG.PSU__DDRC__MEMORY_TYPE {DDR 4} \
  CONFIG.PSU__DDRC__BUS_WIDTH {64 Bit} \
  CONFIG.PSU__DDRC__ECC {Disabled} \
  CONFIG.PSU__DDRC__DEVICE_CAPACITY {8192 MBits} \
  CONFIG.PSU__DDRC__DRAM_WIDTH {16 Bits} \
  CONFIG.PSU__DDRC__ROW_ADDR_COUNT {16} \
  CONFIG.PSU__DDRC__BG_ADDR_COUNT {1} \
  CONFIG.PSU__DDR_HIGH_ADDRESS_GUI_ENABLE {1} \
  CONFIG.PSU_DDR_RAM_LOWADDR_OFFSET {0x80000000} \
  CONFIG.PSU_DDR_RAM_HIGHADDR_OFFSET {0x800000000} \
  CONFIG.PSU_DDR_RAM_HIGHADDR {0xFFFFFFFF}] $ps

set smartconnect_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_0]
set_property -dict [list CONFIG.NUM_MI {2} CONFIG.NUM_SI {1}] $smartconnect_0

connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] [get_bd_intf_pins smartconnect_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M00_AXI] [get_bd_intf_ports M_AXI_CTRL]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M01_AXI] [get_bd_intf_ports M_AXI_INST]
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM1_FPD] [get_bd_intf_ports M_AXI_PS_DDR]

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_ports pl_clk] [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk] [get_bd_pins smartconnect_0/aclk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_ports pl_resetn0]
connect_bd_net [get_bd_ports pl_aresetn] [get_bd_pins smartconnect_0/aresetn]
connect_bd_net [get_bd_ports ddr4_ui_clk] [get_bd_pins zynq_ultra_ps_e_0/maxihpm1_fpd_aclk]

assign_bd_address -offset 0xA0000000 -range 0x00010000 -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs M_AXI_CTRL/Reg] -force
assign_bd_address -offset 0xA0020000 -range 0x00008000 -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs M_AXI_INST/Reg] -force
assign_bd_address -offset 0x004800000000 -range 0x000200000000 -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs M_AXI_PS_DDR/Reg] -force

validate_bd_design
save_bd_design
