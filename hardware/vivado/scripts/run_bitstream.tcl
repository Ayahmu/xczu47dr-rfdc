# Vivado Bitstream Generation Script

set script_path [file dirname [file normalize [info script]]]
set vivado_dir [file dirname $script_path]
source "${script_path}/target_config.tcl"
source "${script_path}/reference_xxv_dcp.tcl"

set target "zcu216"
if {$argc > 0} {
    set target [lindex $argv 0]
}
if {![target_config_exists $target]} {
    target_config_error $target
}

set proj_name [target_config_get $target project_basename]
set output_basename [target_config_get $target output_basename]
set proj_dir "${vivado_dir}/work"
set proj_file "${proj_dir}/${proj_name}.xpr"
set output_dir "${vivado_dir}/output"

puts "INFO: Opening project ${proj_file}"
open_project ${proj_file}

# Do not reset or regenerate XXV Ethernet during bitstream generation.
# The generated Design_Linking checkpoint cannot produce a bitstream in this environment.
# Restore the known-good reference checkpoint instead.
restore_reference_xxv_dcp ${vivado_dir} ${target}

# Create output directory
file mkdir ${output_dir}

set impl_dir "${proj_dir}/${proj_name}.runs/impl_1"
set existing_bit_files [glob -nocomplain ${impl_dir}/*.bit]
if {[llength $existing_bit_files] == 0} {
    puts "INFO: Generating bitstream..."
    launch_runs impl_1 -to_step write_bitstream -jobs 8
    wait_on_run impl_1
} else {
    puts "INFO: Reusing existing bitstream: [lindex $existing_bit_files 0]"
}

# Check bitstream generation status
set bit_status [get_property STATUS [get_runs impl_1]]
set bit_progress [get_property PROGRESS [get_runs impl_1]]

puts "INFO: Bitstream status: ${bit_status}"
puts "INFO: Bitstream progress: ${bit_progress}"

if {${bit_progress} != "100%"} {
    puts "ERROR: Bitstream generation failed!"
    exit 1
}

# Copy bitstream and debug files to output directory
set bit_file "${impl_dir}/*.bit"
set ltx_file "${impl_dir}/*.ltx"

puts "INFO: Copying bitstream to output directory..."
set bit_files [glob -nocomplain ${bit_file}]
if {[llength $bit_files] > 0} {
    file copy -force [lindex $bit_files 0] ${output_dir}/${output_basename}.bit
    puts "INFO: Bitstream copied to ${output_dir}/${output_basename}.bit"
} else {
    puts "ERROR: Bitstream file not found!"
    exit 1
}

# Copy debug probe file if exists
set ltx_files [glob -nocomplain ${ltx_file}]
if {[llength $ltx_files] > 0} {
    file copy -force [lindex $ltx_files 0] ${output_dir}/${output_basename}.ltx
    puts "INFO: Debug probes copied to ${output_dir}/${output_basename}.ltx"
}

set timing_rpt "${impl_dir}/reports/post_impl_timing.rpt"
if {[file exists ${timing_rpt}]} {
    file copy -force ${timing_rpt} ${output_dir}/${output_basename}_timing.rpt
    puts "INFO: Timing report copied to ${output_dir}/${output_basename}_timing.rpt"
}

puts "INFO: Bitstream generation complete"
close_project
