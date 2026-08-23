# Vivado XSA Export Script

set script_path [file dirname [file normalize [info script]]]
set vivado_dir [file dirname $script_path]
source "${script_path}/target_config.tcl"

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
set impl_dir "${proj_dir}/${proj_name}.runs/impl_1"

puts "INFO: Opening project ${proj_file}"
open_project ${proj_file}

# Create output directory
file mkdir ${output_dir}

# The custom implementation flow writes a routed checkpoint and bitstream
# directly after binding the protected XXV Ethernet DCP.  Opening impl_1 can
# cause Vivado to recreate that run, so export from the completed checkpoint
# instead.  This keeps XSA generation read-only with respect to the isolated
# project tree.
set implemented_dcp "${impl_dir}/TopCustomXczu47dr_postroute_physopt.dcp"
if {![file exists ${implemented_dcp}]} {
    set implemented_dcp "${impl_dir}/TopCustomXczu47dr_routed.dcp"
}
if {![file exists ${implemented_dcp}]} {
    puts "ERROR: no routed implementation checkpoint found in ${impl_dir}"
    puts "ERROR: run the corresponding bitstream target before exporting XSA"
    exit 1
}
puts "INFO: Opening implemented checkpoint ${implemented_dcp}"
open_checkpoint ${implemented_dcp}

puts "INFO: Exporting hardware platform (XSA)..."
set xsa_file "${output_dir}/${output_basename}.xsa"

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
