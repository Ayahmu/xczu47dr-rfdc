#!/usr/bin/env vivado -mode batch -source
# Export Hardware Specification (XSA)

set script_dir [file dirname [file normalize [info script]]]
set work_dir "${script_dir}/work"
set proj_name "zcu216_rfdc"
set output_dir "${script_dir}/output"

open_project ${work_dir}/${proj_name}.xpr

# Create output directory
file mkdir ${output_dir}

# Export XSA with bitstream
write_hw_platform -fixed -include_bit -force -file ${output_dir}/${proj_name}.xsa

puts "=========================================="
puts "XSA exported successfully"
puts "Location: ${output_dir}/${proj_name}.xsa"
puts "=========================================="
