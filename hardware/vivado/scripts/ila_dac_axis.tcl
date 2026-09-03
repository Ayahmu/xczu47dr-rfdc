set script_folder [file dirname [file normalize [info script]]]
if {![llength [info commands target_config_get]]} {
  source "${script_folder}/target_config.tcl"
}
if {![llength [info commands build_option_get]]} {
  source "${script_folder}/build_options.tcl"
}

set list_projs [get_projects -quiet]
if { $list_projs eq "" } {
  set target "custom_xczu47dr"
  if {[info exists argc] && $argc > 0} {
    set target [lindex $argv 0]
  }
  create_project ${target}_ila_dac_axis work -part [target_config_get $target part]
  set_property target_language Verilog [current_project]
  set_property simulator_language Mixed [current_project]
}

set ila_name ila_dac_axis
if {[llength [get_ips -quiet ${ila_name}]] == 0} {
  create_ip -name ila -vendor xilinx.com -library ip -module_name ${ila_name}
}

# ILA capture depth.  1024 is the IP's minimum legal value (valid set is
# 1024, 2048, 4096, ...), so depth is not a lever for cutting BRAM here -
# probe width is.  Override with ILA_DEPTH=<n> in the env.
set ila_data_depth [build_option_get ILA_DEPTH 1024]

# probe1..probe8 carry the eight channels' RFDC tdata.  At the full 256-bit
# beat width they alone were 2048 of this ILA's 3172 bits, i.e. ~58 of the ~89
# RAMB36 it consumed - and ILA buffers were 64% of all BRAM in the design,
# which is what drove routing congestion to level 5 at only 20% LUT use.
# 32 bits keeps the first complex sample of each beat, which is what the
# trigger/launch timing work actually needs.  Widen back to 256 if a waveform
# content bug needs the whole beat.
set_property -dict [list \
  CONFIG.C_NUM_OF_PROBES {17} \
  CONFIG.C_DATA_DEPTH ${ila_data_depth} \
  CONFIG.C_PROBE0_WIDTH {128} \
  CONFIG.C_PROBE1_WIDTH {32} \
  CONFIG.C_PROBE2_WIDTH {32} \
  CONFIG.C_PROBE3_WIDTH {32} \
  CONFIG.C_PROBE4_WIDTH {32} \
  CONFIG.C_PROBE5_WIDTH {32} \
  CONFIG.C_PROBE6_WIDTH {32} \
  CONFIG.C_PROBE7_WIDTH {32} \
  CONFIG.C_PROBE8_WIDTH {32} \
  CONFIG.C_PROBE9_WIDTH {256} \
  CONFIG.C_PROBE10_WIDTH {256} \
  CONFIG.C_PROBE11_WIDTH {256} \
  CONFIG.C_PROBE12_WIDTH {32} \
  CONFIG.C_PROBE13_WIDTH {64} \
  CONFIG.C_PROBE14_WIDTH {64} \
  CONFIG.C_PROBE15_WIDTH {64} \
  CONFIG.C_PROBE16_WIDTH {4} \
] [get_ips ${ila_name}]

generate_target all [get_ips ${ila_name}]
