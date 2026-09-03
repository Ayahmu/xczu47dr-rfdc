# Verify that every "get_pins -quiet <pattern>" in the role XDC still matches
# something in the synthesized netlist.
#
# XDC files only accept a whitelisted subset of Tcl - no foreach/if/puts - so a
# renamed synchronizer silently turns its "-quiet" constraint into a no-op.  Six
# constraints in custom_xczu47dr_minimal.xdc had rotted that way, including the
# hmc_pl_clk -> dac_axis_clk Trigger CDC.  This runs as a normal Tcl script,
# where the loop is allowed.
#
# Usage (after synthesis, from hardware/vivado):
#   vivado -mode batch -notrace -source scripts/check_xdc_pins.tcl \
#          -tclargs custom_xczu47dr_slave

set script_folder [file dirname [file normalize [info script]]]
if {![llength [info commands target_config_get]]} {
  source "${script_folder}/target_config.tcl"
}

set target "custom_xczu47dr_slave"
if {[info exists argc] && $argc > 0} {
  set target [lindex $argv 0]
}

set work_dir [expr {[info exists ::env(VIVADO_WORK_DIR)]
                    ? $::env(VIVADO_WORK_DIR)
                    : "[file dirname ${script_folder}]/work"}]
set project_basename [target_config_get $target project_basename]
set top_module [target_config_get $target top_module]
set dcp "${work_dir}/${project_basename}.runs/synth_1/${top_module}.dcp"

if {[llength [get_designs -quiet]] == 0} {
  if {![file exists ${dcp}]} {
    puts "ERROR: no open design and no synthesis checkpoint at ${dcp}"
    exit 1
  }
  open_checkpoint ${dcp}
}

set vivado_dir [file dirname ${script_folder}]
set xdc_files [list]
foreach rel [target_config_get $target xdc_files] {
  lappend xdc_files "${vivado_dir}/${rel}"
}

set dead 0
set live 0
foreach xdc ${xdc_files} {
  if {![file exists ${xdc}]} { continue }
  set fh [open ${xdc} r]
  set body [read ${fh}]
  close ${fh}
  foreach line [split ${body} "\n"] {
    set trimmed [string trim ${line}]
    if {[string index ${trimmed} 0] eq "#"} { continue }
    # Greedy \S+ followed by the closing bracket, so a pattern that itself
    # contains brackets (foo_reg[0]/D) is captured whole instead of being cut at
    # the first "]".
    if {![regexp {get_pins\s+-quiet\s+(\S+)\]} ${trimmed} -> pattern]} { continue }
    if {[catch {llength [get_pins -quiet ${pattern}]} count]} {
      puts "CRITICAL WARNING: unparsable XDC pin pattern in [file tail ${xdc}]: ${pattern}"
      incr dead
    } elseif {${count} == 0} {
      puts "CRITICAL WARNING: dead XDC pin pattern in [file tail ${xdc}]: ${pattern}"
      incr dead
    } else {
      incr live
    }
  }
}

puts "XDC pin check: ${live} live, ${dead} dead"
if {${dead} > 0} {
  puts "ERROR: ${dead} XDC constraint(s) match nothing and are silently inactive"
  exit 1
}
exit 0
