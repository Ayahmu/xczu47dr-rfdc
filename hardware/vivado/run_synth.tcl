#!/usr/bin/env vivado -mode batch -source
# Run Synthesis

set script_dir [file dirname [file normalize [info script]]]
set work_dir "${script_dir}/work"
set proj_name "zcu216_rfdc"

open_project ${work_dir}/${proj_name}.xpr

reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthesis failed"
    exit 1
}

puts "Synthesis completed successfully"
