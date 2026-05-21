set script_folder [file dirname [file normalize [info script]]]
if {![llength [info commands target_config_get]]} {
  source "${script_folder}/target_config.tcl"
}

set list_projs [get_projects -quiet]
if { $list_projs eq "" } {
  set target "zcu216"
  if {[info exists argc] && $argc > 0} {
    set target [lindex $argv 0]
  }
  create_project ${target}_ila_udp_ddr work -part [target_config_get $target part]
  set_property target_language Verilog [current_project]
  set_property simulator_language Mixed [current_project]
}

set ila_name ila_udp_ddr
if {[llength [get_ips -quiet ${ila_name}]] == 0} {
  create_ip -name ila -vendor xilinx.com -library ip -module_name ${ila_name}
}

set_property -dict [list \
  CONFIG.C_NUM_OF_PROBES {12} \
  CONFIG.C_DATA_DEPTH {4096} \
  CONFIG.C_PROBE0_WIDTH {128} \
  CONFIG.C_PROBE1_WIDTH {64} \
  CONFIG.C_PROBE2_WIDTH {128} \
  CONFIG.C_PROBE3_WIDTH {128} \
  CONFIG.C_PROBE4_WIDTH {128} \
  CONFIG.C_PROBE5_WIDTH {104} \
  CONFIG.C_PROBE6_WIDTH {128} \
  CONFIG.C_PROBE7_WIDTH {128} \
  CONFIG.C_PROBE8_WIDTH {128} \
  CONFIG.C_PROBE9_WIDTH {128} \
  CONFIG.C_PROBE10_WIDTH {128} \
  CONFIG.C_PROBE11_WIDTH {128} \
] [get_ips ${ila_name}]

generate_target all [get_ips ${ila_name}]
