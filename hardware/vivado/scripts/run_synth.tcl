# Vivado Synthesis Script

set script_path [file dirname [file normalize [info script]]]
set vivado_dir [file dirname $script_path]
set proj_name "zcu216_rfdc"
set proj_dir "${vivado_dir}/work"
set proj_file "${proj_dir}/${proj_name}.xpr"

puts "INFO: Opening project ${proj_file}"
open_project ${proj_file}

puts "INFO: Starting synthesis..."
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1

# Check synthesis status
set synth_status [get_property STATUS [get_runs synth_1]]
set synth_progress [get_property PROGRESS [get_runs synth_1]]

puts "INFO: Synthesis status: ${synth_status}"
puts "INFO: Synthesis progress: ${synth_progress}"

if {${synth_status} != "synth_design Complete!"} {
    puts "ERROR: Synthesis failed!"
    exit 1
}

# Open synthesized design for reporting
open_run synth_1

# Generate reports
set report_dir "${vivado_dir}/work/${proj_name}.runs/synth_1/reports"
file mkdir ${report_dir}

puts "INFO: Generating synthesis reports..."
report_utilization -file ${report_dir}/post_synth_util.rpt
report_timing_summary -file ${report_dir}/post_synth_timing.rpt

puts "INFO: Synthesis complete"
close_project
