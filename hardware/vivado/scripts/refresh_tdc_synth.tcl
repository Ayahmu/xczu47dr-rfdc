# Rebuild the parent RTL after an initial complete project/OOC synthesis.
set script_path [file dirname [file normalize [info script]]]
set vivado_dir [file dirname $script_path]
source ${script_path}/target_config.tcl
source ${script_path}/reference_xxv_dcp.tcl
set target [lindex $argv 0]
if {![target_config_exists $target]} {target_config_error $target}
set proj_name [target_config_get $target project_basename]
set proj_dir $::env(VIVADO_WORK_DIR)
open_project ${proj_dir}/${proj_name}.xpr
foreach run [get_runs -quiet *_synth_1] {
    if {[string match *xxv* $run]} {continue}
    set status [get_property STATUS $run]
    if {$status ne "synth_design Complete!" && [get_property PROGRESS $run] ne "100%"} {
        error "OOC run is not ready for RTL-only refresh: $run ($status)"
    }
}
foreach src [glob ${vivado_dir}/src/tdc_*.v ${vivado_dir}/src/iq_*.v] {
    if {[llength [get_files -quiet $src]] == 0} {add_files -norecurse $src}
}
foreach rel [target_config_get $target xdc_files] {
    set xdc ${vivado_dir}/$rel
    if {[llength [get_files -quiet $xdc]] == 0} {add_files -fileset constrs_1 -norecurse $xdc}
}
set_property USED_IN_SYNTHESIS false [get_files */tdc_placement.xdc]
set_property USED_IN_SYNTHESIS false [get_files */tdc_timing.xdc]
update_compile_order -fileset sources_1
restore_reference_xxv_dcp $vivado_dir $proj_dir $target $proj_name
prepare_reference_xxv_ooc_run $vivado_dir $proj_dir $target $proj_name
reset_run impl_1
reset_run synth_1
set_property incremental_checkpoint {} [get_runs synth_1]
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    error "TDC parent synthesis failed"
}
puts "TDC_SYNTHESIS_COMPLETE"
close_project
