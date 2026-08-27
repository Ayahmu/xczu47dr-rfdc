# Export Vivado debug probes from the routed checkpoint that produced the
# matching bitstream. This does not rerun synthesis or implementation.

set script_path [file dirname [file normalize [info script]]]
source "${script_path}/target_config.tcl"

set target "custom_xczu47dr_master"
if {$argc > 0} {
    set target [lindex $argv 0]
}
if {![target_config_exists $target]} {
    target_config_error $target
}

set vivado_dir [file dirname $script_path]
set proj_name [target_config_get $target project_basename]
set output_basename [target_config_get $target output_basename]
set proj_dir [expr {[info exists ::env(VIVADO_WORK_DIR)] ? $::env(VIVADO_WORK_DIR) : "${vivado_dir}/work"}]
set output_dir [expr {[info exists ::env(VIVADO_OUTPUT_DIR)] ? $::env(VIVADO_OUTPUT_DIR) : "${vivado_dir}/output"}]
set impl_dir "${proj_dir}/${proj_name}.runs/impl_1"

set routed_dcp "${impl_dir}/TopCustomXczu47dr_postroute_physopt.dcp"
if {![file exists ${routed_dcp}]} {
    set routed_dcp "${impl_dir}/TopCustomXczu47dr_routed.dcp"
}
if {![file exists ${routed_dcp}]} {
    error "No routed checkpoint found in ${impl_dir}; build the bitstream first"
}

file mkdir ${output_dir}
set ltx_output "${output_dir}/${output_basename}.ltx"
set ltx_tmp "${output_dir}/${output_basename}.tmp.ltx"
file delete -force ${ltx_tmp}

puts "INFO: Opening routed checkpoint ${routed_dcp}"
open_checkpoint ${routed_dcp}
set debug_cores [get_debug_cores -quiet]
if {[llength ${debug_cores}] == 0} {
    close_design
    error "No debug cores found in ${routed_dcp}; this implementation has no ILA probes"
}
puts "INFO: Found [llength ${debug_cores}] debug cores"
write_debug_probes -force ${ltx_tmp}
close_design

if {![file exists ${ltx_tmp}] || [file size ${ltx_tmp}] == 0} {
    error "Vivado did not produce a non-empty debug probe file"
}
file rename -force ${ltx_tmp} ${ltx_output}
puts "INFO: Debug probes exported to ${ltx_output} ([file size ${ltx_output}] bytes)"
