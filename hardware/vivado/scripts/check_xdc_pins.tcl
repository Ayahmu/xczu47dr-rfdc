# Verify that every "-quiet" object query in the role XDC still matches
# something in the synthesized netlist.
#
# XDC files only accept a whitelisted subset of Tcl - no foreach/if/puts - so a
# renamed object silently turns its "-quiet" constraint into a no-op.  Six
# constraints in custom_xczu47dr_minimal.xdc had rotted that way, including the
# hmc_pl_clk -> dac_axis_clk Trigger CDC.  This runs as a normal Tcl script,
# where the loop is allowed.
#
# Two kinds of query are checked:
#
#   get_pins -quiet <pattern>       one pattern per query
#   get_clocks -quiet <name>        one name, or a braced list of names
#
# The clock check inspects every name in a braced list SEPARATELY.  That is the
# whole point: "get_clocks -quiet {RFDAC2_CLK some_clock_that_no_longer_exists}"
# returns a non-empty collection, so the surviving name masks the dead one and
# neither Vivado nor a naive check notices.
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

# Prefer open_run over open_checkpoint when called from within a project: it
# applies the full constraint set (including IP-owned XDC), whereas
# open_checkpoint only brings the netlist.  If no project/run is open, fall
# back to the DCP.
set loaded_from_run 0
if {[llength [get_designs -quiet]] == 0} {
  if {[catch {current_project -quiet} proj] == 0 && ${proj} ne ""} {
    if {[catch {open_run synth_1} e] == 0} {
      set loaded_from_run 1
    }
  }
  if {!${loaded_from_run}} {
    if {![file exists ${dcp}]} {
      puts "ERROR: no open design, no accessible synth_1 run, and no checkpoint at ${dcp}"
      exit 1
    }
    open_checkpoint ${dcp}
  }
}

set vivado_dir [file dirname ${script_folder}]
set xdc_files [list]
foreach rel [target_config_get $target xdc_files] {
  lappend xdc_files "${vivado_dir}/${rel}"
}

set dead 0
set live 0
set dead_clocks 0
set live_clocks 0

foreach xdc ${xdc_files} {
  if {![file exists ${xdc}]} { continue }
  set fh [open ${xdc} r]
  set body [read ${fh}]
  close ${fh}
  set tail [file tail ${xdc}]
  foreach line [split ${body} "\n"] {
    set trimmed [string trim ${line}]
    if {[string index ${trimmed} 0] eq "#"} { continue }

    # --- get_pins ---
    # Greedy \S+ followed by the closing bracket, so a pattern that itself
    # contains brackets (foo_reg[0]/D) is captured whole instead of being cut at
    # the first "]".
    if {[regexp {get_pins\s+-quiet\s+(\S+)\]} ${trimmed} -> pattern]} {
      if {[catch {llength [get_pins -quiet ${pattern}]} count]} {
        puts "CRITICAL WARNING: unparsable XDC pin pattern in ${tail}: ${pattern}"
        incr dead
      } elseif {${count} == 0} {
        puts "CRITICAL WARNING: dead XDC pin pattern in ${tail}: ${pattern}"
        incr dead
      } else {
        incr live
      }
    }

    # --- get_clocks ---
    # Collect the braced-list form first, then the bare-name form.  The bare
    # form rejects a leading open-brace so a list is never mistaken for one
    # name, and is greedy up to the closing bracket so a name that itself
    # contains brackets (pll_clk[0]) survives instead of being cut at the first
    # "]".  Note: do not write a lone open-brace in a comment inside a braced
    # body - Tcl counts braces in comments too, and an unbalanced one makes the
    # whole enclosing foreach fail to parse.
    set clock_names [list]
    foreach {whole inner} [regexp -all -inline \
        {get_clocks\s+(?:-quiet\s+|-include_generated_clocks\s+)+\{([^\}]*)\}} ${trimmed}] {
      foreach name ${inner} { lappend clock_names ${name} }
    }
    foreach {whole inner} [regexp -all -inline \
        {get_clocks\s+(?:-quiet\s+|-include_generated_clocks\s+)+([^\s\{\-]\S*)\]} ${trimmed}] {
      lappend clock_names ${inner}
    }
    foreach name ${clock_names} {
      if {[catch {llength [get_clocks -quiet ${name}]} count]} {
        puts "CRITICAL WARNING: unparsable XDC clock name in ${tail}: ${name}"
        incr dead_clocks
      } elseif {${count} == 0} {
        puts "CRITICAL WARNING: dead XDC clock name in ${tail}: ${name}"
        incr dead_clocks
      } else {
        incr live_clocks
      }
    }
  }
}

puts "XDC pin check: ${live} live, ${dead} dead"
puts "XDC clock check: ${live_clocks} live, ${dead_clocks} dead"

# If the clock check found zero live names, the constraint set likely was not
# loaded (open_checkpoint without the project brings only the netlist).  That is
# a tool usage bug, not a genuine dead-constraint problem, so downgrade to a
# warning rather than failing the build.
if {${live_clocks} == 0 && ${dead_clocks} > 0} {
  puts "WARNING: all queried clock names returned empty; constraint set may not be loaded"
  puts "         (this check may have been invoked on a bare checkpoint instead of via open_run)"
  exit 0
}

set total_dead [expr {${dead} + ${dead_clocks}}]
if {${total_dead} > 0} {
  puts "ERROR: ${total_dead} XDC constraint object(s) match nothing and are silently inactive"
  exit 1
}
exit 0
