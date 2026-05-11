# Vivado XSA Export Script

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

# Open implemented design
open_run impl_1

puts "INFO: Exporting hardware platform (XSA)..."
set xsa_file "${output_dir}/${proj_name}.xsa"

# Export XSA with bitstream
write_hw_platform -fixed -force -include_bit -file ${xsa_file}

if {[file exists ${xsa_file}]} {
    set xsa_size [file size ${xsa_file}]
    set xsa_size_mb [expr {$xsa_size / 1024.0 / 1024.0}]
    puts "INFO: XSA exported successfully"
    puts "INFO: File: ${xsa_file}"
    puts "INFO: Size: [format "%.2f" ${xsa_size_mb}] MB"
} else {
    puts "ERROR: XSA export failed!"
    exit 1
}

puts "INFO: XSA export complete"
close_project
