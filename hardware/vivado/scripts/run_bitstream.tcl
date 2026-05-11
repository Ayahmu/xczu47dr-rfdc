# Vivado Bitstream Generation Script

set script_path [file dirname [file normalize [info script]]]
set vivado_dir [file dirname $script_path]
set proj_name "zcu216_rfdc"
set proj_dir "${vivado_dir}/work"
set proj_file "${proj_dir}/${proj_name}.xpr"
set output_dir "${vivado_dir}/output"

puts "INFO: Opening project ${proj_file}"
open_project ${proj_file}

# Create output directory
file mkdir ${output_dir}

puts "INFO: Generating bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

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
set impl_dir "${proj_dir}/${proj_name}.runs/impl_1"
set bit_file "${impl_dir}/*_wrapper.bit"
set ltx_file "${impl_dir}/*_wrapper.ltx"

puts "INFO: Copying bitstream to output directory..."
set bit_files [glob -nocomplain ${bit_file}]
if {[llength $bit_files] > 0} {
    file copy -force [lindex $bit_files 0] ${output_dir}/${proj_name}.bit
    puts "INFO: Bitstream copied to ${output_dir}/${proj_name}.bit"
} else {
    puts "ERROR: Bitstream file not found!"
    exit 1
}

# Copy debug probe file if exists
set ltx_files [glob -nocomplain ${ltx_file}]
if {[llength $ltx_files] > 0} {
    file copy -force [lindex $ltx_files 0] ${output_dir}/${proj_name}.ltx
    puts "INFO: Debug probes copied to ${output_dir}/${proj_name}.ltx"
}

puts "INFO: Bitstream generation complete"
close_project
