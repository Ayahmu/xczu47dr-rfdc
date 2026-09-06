# Create 200 MHz clock from 104 MHz input for external trigger phase detection
# Used by ext_trigger_phase_detector to achieve 5 ns phase resolution (4 phases of 20 ns beat)

set script_folder [file dirname [file normalize [info script]]]
if {![llength [info commands target_config_get]]} {
  source "${script_folder}/target_config.tcl"
}

set list_projs [get_projects -quiet]
if { $list_projs eq "" } {
  set target "custom_xczu47dr"
  if {[info exists argc] && $argc > 0} {
    set target [lindex $argv 0]
  }
  create_project ${target}_clk_gen_200mhz work -part [target_config_get $target part]
  set_property target_language Verilog [current_project]
  set_property simulator_language Mixed [current_project]
}

set ip_name clk_gen_200mhz
if {[llength [get_ips -quiet ${ip_name}]] == 0} {
  create_ip -name clk_wiz -vendor xilinx.com -library ip -module_name ${ip_name}
}

# 104.166667 MHz input -> 200 MHz output
# PLL configuration:
#   Input: 104.166667 MHz (clk104_clk from PS)
#   VCO: 1000 MHz (M=48, D=5 gives 104.166667 * 48/5 = 1000)
#   Output: 200 MHz (O=5 gives 1000/5 = 200)
set_property -dict [list \
  CONFIG.PRIM_SOURCE {Single_ended_clock_capable_pin} \
  CONFIG.PRIM_IN_FREQ {104.167} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
  CONFIG.USE_LOCKED {true} \
  CONFIG.USE_RESET {true} \
  CONFIG.RESET_TYPE {ACTIVE_HIGH} \
  CONFIG.RESET_PORT {reset} \
  CONFIG.CLKOUT1_DRIVES {Buffer} \
  CONFIG.FEEDBACK_SOURCE {FDBK_AUTO} \
  CONFIG.MMCM_DIVCLK_DIVIDE {5} \
  CONFIG.MMCM_CLKFBOUT_MULT_F {48.000} \
  CONFIG.MMCM_CLKIN1_PERIOD {9.600} \
  CONFIG.MMCM_CLKOUT0_DIVIDE_F {5.000} \
  CONFIG.CLKOUT1_JITTER {130.958} \
  CONFIG.CLKOUT1_PHASE_ERROR {98.575} \
] [get_ips ${ip_name}]

generate_target all [get_ips ${ip_name}]
