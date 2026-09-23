# Export Vivado debug probes from the routed checkpoint that produced the
# matching bitstream. This does not rerun synthesis or implementation.

set script_path [file dirname [file normalize [info script]]]
source "${script_path}/target_config.tcl"

set target "custom_xczu47dr_waveform"
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
set proj_file "${proj_dir}/${proj_name}.xpr"
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

puts "INFO: Opening project ${proj_file}"
open_project ${proj_file}
set impl_run [get_runs -quiet impl_1]
set impl_status [expr {[llength ${impl_run}] == 1 ? [get_property STATUS ${impl_run}] : ""}]
set impl_progress [expr {[llength ${impl_run}] == 1 ? [get_property PROGRESS ${impl_run}] : ""}]
if {[llength ${impl_run}] != 1 || ${impl_progress} ne "100%" ||
    ![string match "*Complete*" ${impl_status}]} {
    error "Project-managed impl_1 is not a completed routed run (status=${impl_status}, progress=${impl_progress}); refusing LTX export"
}
puts "INFO: Opening completed project-managed routed run for ${routed_dcp}"
open_run impl_1
set debug_cores [get_debug_cores -quiet]
if {[llength ${debug_cores}] == 0} {
    close_project
    error "No debug cores found in ${routed_dcp}; this implementation has no ILA probes"
}
puts "INFO: Found [llength ${debug_cores}] debug cores"
write_debug_probes -force ${ltx_tmp}
close_project

if {![file exists ${ltx_tmp}] || [file size ${ltx_tmp}] == 0} {
    error "Vivado did not produce a non-empty debug probe file"
}
file rename -force ${ltx_tmp} ${ltx_output}
puts "INFO: Debug probes exported to ${ltx_output} ([file size ${ltx_output}] bytes)"
