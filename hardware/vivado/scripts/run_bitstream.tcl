# Vivado Bitstream Generation Script

set script_path [file dirname [file normalize [info script]]]
set vivado_dir [file dirname $script_path]
source "${script_path}/target_config.tcl"
source "${script_path}/reference_xxv_dcp.tcl"
source "${script_path}/build_options.tcl"

set target "custom_xczu47dr_master"
if {$argc > 0} {
    set target [lindex $argv 0]
}
if {![target_config_exists $target]} {
    target_config_error $target
}

set proj_name [target_config_get $target project_basename]
set output_basename [target_config_get $target output_basename]
set proj_dir [expr {[info exists ::env(VIVADO_WORK_DIR)] ? $::env(VIVADO_WORK_DIR) : "${vivado_dir}/work"}]
set proj_file "${proj_dir}/${proj_name}.xpr"
set output_dir [expr {[info exists ::env(VIVADO_OUTPUT_DIR)] ? $::env(VIVADO_OUTPUT_DIR) : "${vivado_dir}/output"}]

puts "INFO: Opening project ${proj_file}"
open_project ${proj_file}
restore_reference_xxv_dcp ${vivado_dir} ${proj_dir} ${target} ${proj_name}

# Keep the parent-only XXV model out of implementation/bitstream generation.
set bit_defines [get_property verilog_define [current_fileset]]
set bit_defines [lsearch -all -inline -not -exact ${bit_defines} PARENT_RTL_SYNTH]
set_property verilog_define ${bit_defines} [current_fileset]
foreach f [get_files -quiet -all *xxv_ethernet_parent_stub.v] {
    set_property USED_IN_IMPLEMENTATION false ${f}
}

# Do not reset or regenerate XXV Ethernet during bitstream generation.
# The generated Design_Linking checkpoint cannot produce a bitstream in this environment.
# Restore the known-good reference checkpoint instead.
#restore_reference_xxv_dcp ${vivado_dir} ${target}

# Create output directory
file mkdir ${output_dir}

set impl_dir "${proj_dir}/${proj_name}.runs/impl_1"
set manual_bit_file "${impl_dir}/${proj_name}.bit"
set existing_bit_files [glob -nocomplain ${impl_dir}/*.bit]
set manual_bitstream 0
if {[file exists ${manual_bit_file}]} {
    # run_impl_manual.tcl writes a checked routed design and bitstream
    # directly because the project-managed impl_1 run cannot bind the
    # protected XXV Ethernet DCP to the parent black-box cell.
    set existing_bit_files [list ${manual_bit_file}]
    set manual_bitstream 1
    puts "INFO: Reusing manually implemented bitstream: ${manual_bit_file}"
} elseif {[llength $existing_bit_files] == 0} {
    puts "INFO: Generating bitstream..."
    launch_runs impl_1 -to_step write_bitstream -jobs 8
    wait_on_run impl_1
} else {
    puts "INFO: Reusing existing bitstream: [lindex $existing_bit_files 0]"
}

# Check bitstream generation status
if {!${manual_bitstream}} {
    set bit_status [get_property STATUS [get_runs impl_1]]
    set bit_progress [get_property PROGRESS [get_runs impl_1]]

    puts "INFO: Bitstream status: ${bit_status}"
    puts "INFO: Bitstream progress: ${bit_progress}"

    if {${bit_progress} != "100%"} {
        puts "ERROR: Bitstream generation failed!"
        exit 1
    }
}

# Copy bitstream and debug files to output directory
set bit_file "${impl_dir}/*.bit"
set ltx_file "${impl_dir}/*.ltx"

puts "INFO: Copying bitstream to output directory..."
set bit_files [glob -nocomplain ${bit_file}]
if {[llength $bit_files] > 0} {
    set bit_output "${output_dir}/${output_basename}.bit"
    set bit_tmp "${bit_output}.tmp"
    file delete -force ${bit_tmp}
    file copy -force [lindex $bit_files 0] ${bit_tmp}
    file rename -force ${bit_tmp} ${bit_output}
    puts "INFO: Bitstream copied to ${output_dir}/${output_basename}.bit"
} else {
    puts "ERROR: Bitstream file not found!"
    exit 1
}

# Copy debug probe file if exists
set ltx_files [glob -nocomplain ${ltx_file}]
if {[llength $ltx_files] > 0} {
    set ltx_output "${output_dir}/${output_basename}.ltx"
    set ltx_tmp "${ltx_output}.tmp"
    file delete -force ${ltx_tmp}
    file copy -force [lindex $ltx_files 0] ${ltx_tmp}
    file rename -force ${ltx_tmp} ${ltx_output}
    puts "INFO: Debug probes copied to ${output_dir}/${output_basename}.ltx"
} else {
    # Never leave an older role/build's probes next to a fresh bitstream.
    set ltx_output "${output_dir}/${output_basename}.ltx"
    if {[file exists ${ltx_output}]} {
        file delete -force ${ltx_output}
        puts "INFO: Removed stale debug probes: ${ltx_output}"
    }
}

set timing_rpt "${impl_dir}/TopCustomXczu47dr_timing_summary_postroute_physopted.rpt"
if {![file exists ${timing_rpt}]} {
    set timing_rpt "${impl_dir}/reports/post_impl_timing.rpt"
}
if {[file exists ${timing_rpt}]} {
    file copy -force ${timing_rpt} ${output_dir}/${output_basename}_timing.rpt
    puts "INFO: Timing report copied to ${output_dir}/${output_basename}_timing.rpt"
}

# Timing gate.  This design routes at level-5 congestion with only ~20% LUT use,
# so WNS swings across builds and has landed anywhere from -0.070 ns to
# +0.107 ns.  Nothing downstream checked it, which meant a bitstream that misses
# timing could be written into artifacts/ and flashed without anyone noticing.
# Abort instead, unless TIMING_GATE=0 is set in the environment.
set timing_gate [build_option_get TIMING_GATE 1]
set routed_rpt "${impl_dir}/TopCustomXczu47dr_timing_summary_routed.rpt"
if {${timing_gate} && [file exists ${routed_rpt}]} {
    set fh [open ${routed_rpt} r]
    set body [read ${fh}]
    close ${fh}
    if {[regexp {Timing constraints are not met} ${body}]} {
        set wns "?"
        if {[regexp -line {^\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+\d+\s+\d+} ${body} -> wns tns]} {}
        puts "ERROR: implementation does not meet timing (WNS=${wns} ns)."
        puts "       Refusing to publish ${output_basename}.bit - re-run implementation,"
        puts "       reduce ILA probe width/count, or override with TIMING_GATE=0."
        close_project
        exit 1
    }
    puts "INFO: Timing gate passed (all user specified timing constraints are met)"
}

puts "INFO: Bitstream generation complete"
close_project
