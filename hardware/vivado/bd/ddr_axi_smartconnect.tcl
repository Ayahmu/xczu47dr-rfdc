# External DDR AXI interconnect for the custom XCZU47DR target.
# This keeps the main design_1 BD limited to PS/control metadata while the DDR
# arbitration path lives at the top level beside the project-level DDR4 IP.

proc create_ddr_axi_smartconnect_design {} {
  create_bd_design "ddr_axi_smartconnect"
  current_bd_design "ddr_axi_smartconnect"

  set S_AXI_PS [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_PS ]
  set_property -dict [ list \
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
    CONFIG.HAS_REGION {0} \
    CONFIG.HAS_RRESP {1} \
    CONFIG.HAS_WSTRB {1} \
    CONFIG.ID_WIDTH {16} \
    CONFIG.NUM_READ_OUTSTANDING {8} \
    CONFIG.NUM_WRITE_OUTSTANDING {8} \
    CONFIG.PROTOCOL {AXI4} \
    CONFIG.READ_WRITE_MODE {READ_WRITE} \
  ] $S_AXI_PS

  set S_AXI_PL [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_PL ]
  set_property -dict [ list \
    CONFIG.ADDR_WIDTH {64} \
    CONFIG.DATA_WIDTH {128} \
    CONFIG.HAS_BRESP {1} \
    CONFIG.HAS_BURST {1} \
    CONFIG.HAS_CACHE {1} \
    CONFIG.HAS_LOCK {1} \
    CONFIG.HAS_PROT {1} \
    CONFIG.HAS_QOS {1} \
    CONFIG.HAS_REGION {1} \
    CONFIG.HAS_RRESP {1} \
    CONFIG.HAS_WSTRB {1} \
    CONFIG.ID_WIDTH {0} \
    CONFIG.MAX_BURST_LENGTH {256} \
    CONFIG.NUM_READ_OUTSTANDING {1} \
    CONFIG.NUM_READ_THREADS {1} \
    CONFIG.NUM_WRITE_OUTSTANDING {1} \
    CONFIG.NUM_WRITE_THREADS {1} \
    CONFIG.PROTOCOL {AXI4} \
    CONFIG.READ_WRITE_MODE {READ_WRITE} \
    CONFIG.SUPPORTS_NARROW_BURST {1} \
  ] $S_AXI_PL

  set M_AXI_DDR [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_DDR ]
  set_property -dict [ list \
    CONFIG.ADDR_WIDTH {35} \
    CONFIG.DATA_WIDTH {512} \
    CONFIG.HAS_BRESP {1} \
    CONFIG.HAS_BURST {1} \
    CONFIG.HAS_CACHE {1} \
    CONFIG.HAS_LOCK {1} \
    CONFIG.HAS_PROT {1} \
    CONFIG.HAS_QOS {1} \
    CONFIG.HAS_RRESP {1} \
    CONFIG.HAS_WSTRB {1} \
    CONFIG.NUM_READ_OUTSTANDING {8} \
    CONFIG.NUM_WRITE_OUTSTANDING {8} \
    CONFIG.PROTOCOL {AXI4} \
    CONFIG.READ_WRITE_MODE {READ_WRITE} \
  ] $M_AXI_DDR

  set aclk [ create_bd_port -dir I -type clk aclk ]
  set_property -dict [ list \
    CONFIG.ASSOCIATED_BUSIF {S_AXI_PS:S_AXI_PL:M_AXI_DDR} \
    CONFIG.ASSOCIATED_RESET {aresetn} \
  ] $aclk
  set aresetn [ create_bd_port -dir I -from 0 -to 0 -type rst aresetn ]

  set smartconnect_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_0 ]
  set_property -dict [ list \
    CONFIG.NUM_MI {1} \
    CONFIG.NUM_SI {2} \
  ] $smartconnect_0

  connect_bd_intf_net [get_bd_intf_ports S_AXI_PS] [get_bd_intf_pins smartconnect_0/S00_AXI]
  connect_bd_intf_net [get_bd_intf_ports S_AXI_PL] [get_bd_intf_pins smartconnect_0/S01_AXI]
  connect_bd_intf_net [get_bd_intf_ports M_AXI_DDR] [get_bd_intf_pins smartconnect_0/M00_AXI]
  connect_bd_net [get_bd_ports aclk] [get_bd_pins smartconnect_0/aclk]
  connect_bd_net [get_bd_ports aresetn] [get_bd_pins smartconnect_0/aresetn]

  assign_bd_address -offset 0x000500000000 -range 0x000100000000 -target_address_space [get_bd_addr_spaces S_AXI_PS] [get_bd_addr_segs M_AXI_DDR/Reg] -force
  assign_bd_address -offset 0x000500000000 -range 0x000100000000 -target_address_space [get_bd_addr_spaces S_AXI_PL] [get_bd_addr_segs M_AXI_DDR/Reg] -force

  validate_bd_design
  save_bd_design
}

create_ddr_axi_smartconnect_design
