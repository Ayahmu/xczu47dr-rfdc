# Offline harness for hardware/vivado/scripts/check_xdc_pins.tcl.
#
# The checker normally runs inside Vivado against a post-synthesis checkpoint, so
# a mistake in it is only discovered ~10 minutes into a build - and once cost a
# whole two-target build when a lone open-brace in a comment made the enclosing
# foreach fail to parse (Tcl counts braces inside comments too).  This harness
# stubs the handful of Vivado commands the checker uses so it can be executed
# under plain tclsh in milliseconds.  tests/test_check_xdc_pins.py drives it.
#
# usage: tclsh tests/check_xdc_pins_harness.tcl <repo_root> <case>
#   live : every clock name the XDC references exists  -> checker must exit 0
#   dead : one referenced clock name is missing        -> checker must exit 1

set repo [lindex $argv 0]
set mode [lindex $argv 1]

# The clocks the real routed design has, taken from the routed timing summary.
set LIVE_CLOCKS {
  PL_CLK_P_0 RFADC0_CLK RFADC1_CLK RFADC2_CLK RFADC3_CLK
  RFDAC0_CLK RFDAC1_CLK RFDAC2_CLK RFDAC3_CLK
  c0_sys_clk_p mmcm_clkout0 mmcm_clkout5 mmcm_clkout6 clk_pl_0 dna_clk
}
if {$mode eq "dead"} {
  set LIVE_CLOCKS [lsearch -all -inline -not -exact $LIVE_CLOCKS RFDAC2_CLK]
}

proc target_config_get {target key} {
  switch -- $key {
    project_basename { return "custom_xczu47dr_slave_rfdc" }
    top_module       { return "TopCustomXczu47dr" }
    xdc_files        { return [list xdc/custom_xczu47dr_minimal.xdc \
                                   xdc/custom_xczu47dr_slave.xdc] }
  }
  error "harness: unexpected target_config key $key"
}

proc get_designs args { return [list stub_design] }
proc open_checkpoint args { error "harness: the checker must not need a checkpoint" }

# Pin patterns are all reported present: this harness covers the parse and the
# clock path.  The pin list is already exercised for real by every build.
proc get_pins args { return [list stub_pin] }

proc get_clocks args {
  global LIVE_CLOCKS
  set name [lindex $args end]
  if {[lsearch -exact $LIVE_CLOCKS $name] >= 0} { return [list $name] }
  return [list]
}

set argv [list custom_xczu47dr_slave]
set argc 1
cd ${repo}/hardware/vivado
source scripts/check_xdc_pins.tcl
