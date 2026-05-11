#!/usr/bin/env vivado -mode batch -source
# Generate Bitstream

set script_dir [file dirname [file normalize [info script]]]
set work_dir "${script_dir}/work"
set proj_name "zcu216_rfdc"

open_project ${work_dir}/${proj_name}.xpr

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Bitstream generation failed"
    exit 1
}

puts "Bitstream generated successfully"
puts "Location: ${work_dir}/${proj_name}.runs/impl_1/design_1_wrapper.bit"
