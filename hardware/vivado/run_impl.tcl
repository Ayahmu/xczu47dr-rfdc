#!/usr/bin/env vivado -mode batch -source
# Run Implementation

set script_dir [file dirname [file normalize [info script]]]
set work_dir "${script_dir}/work"
set proj_name "zcu216_rfdc"

open_project ${work_dir}/${proj_name}.xpr

reset_run impl_1
launch_runs impl_1 -jobs 8
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation failed"
    exit 1
}

puts "Implementation completed successfully"
