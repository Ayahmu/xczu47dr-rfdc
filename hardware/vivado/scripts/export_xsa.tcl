# Vivado XSA Export Script

set script_path [file dirname [file normalize [info script]]]
set vivado_dir [file dirname $script_path]
source "${script_path}/target_config.tcl"
source "${script_path}/build_identity.tcl"

set target "custom_xczu47dr_waveform"
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
set manifest_file "${proj_dir}/build_manifest.json"
rf2_identity_validate_project ${manifest_file} ${target} ${script_path}

# Create output directory
file mkdir ${output_dir}

# The custom implementation flow writes a routed checkpoint and bitstream
# directly after binding the protected XXV Ethernet DCP.  The project-managed
# impl_1 run is marked complete by the manual flow, so open that completed run
# instead of reopening the physical DCP.  Reopening the DCP replays the XXV GT
# port map and creates avoidable Constraints 18-4866 warnings.
set implemented_dcp "${impl_dir}/TopCustomXczu47dr_postroute_physopt.dcp"
if {![file exists ${implemented_dcp}]} {
    set implemented_dcp "${impl_dir}/TopCustomXczu47dr_routed.dcp"
}
if {![file exists ${implemented_dcp}]} {
    puts "ERROR: no routed implementation checkpoint found in ${impl_dir}"
    puts "ERROR: run the corresponding bitstream target before exporting XSA"
    exit 1
}
rf2_identity_validate_manifest "${implemented_dcp}.manifest.json" ${target} ${script_path}
set impl_run [get_runs -quiet impl_1]
set impl_status [expr {[llength ${impl_run}] == 1 ? [get_property STATUS ${impl_run}] : ""}]
set impl_progress [expr {[llength ${impl_run}] == 1 ? [get_property PROGRESS ${impl_run}] : ""}]
if {[llength ${impl_run}] != 1 || ${impl_progress} ne "100%" ||
    ![string match "*Complete*" ${impl_status}]} {
    error "Project-managed impl_1 is not a completed routed run (status=${impl_status}, progress=${impl_progress}); refusing XSA export"
}
set bit_candidates [glob -nocomplain ${impl_dir}/*.bit]
set selected_bit ""
foreach candidate ${bit_candidates} {
    set candidate_manifest "${candidate}.manifest.json"
    if {[file exists ${candidate_manifest}] &&
        ![catch {rf2_identity_validate_manifest ${candidate_manifest} ${target} ${script_path}}]} {
        set selected_bit ${candidate}
        break
    }
}
if {${selected_bit} eq ""} {
    error "no identity-checked implementation bitstream found in ${impl_dir}"
}
puts "INFO: Opening completed project-managed routed run for ${implemented_dcp}"
open_run impl_1

puts "INFO: Exporting hardware platform (XSA)..."
set xsa_file "${output_dir}/${output_basename}.xsa"
# Vivado requires the output argument to retain the .xsa suffix.  Keep the
# atomic staging file within the same directory while preserving that suffix.
set xsa_tmp "${output_dir}/${output_basename}.tmp.xsa"
file delete -force ${xsa_tmp}

# Export the hardware metadata without asking Vivado to regenerate a bitstream.
# The manual implementation flow already produced and identity-stamped the
# selected bitstream.  write_hw_platform's -include_bit path requires the
# project-managed run to own a write_bitstream result, which is not true for
# this protected-DCP/manual flow and would regenerate a different header.
write_hw_platform -fixed -force -file ${xsa_tmp}

# Embed the exact selected bitstream bytes under the XSA member name expected
# by the identity verifier.  This keeps the XSA payload byte-for-byte aligned
# with the bitstream that was timing/route/DRC checked and avoids a second
# write_bitstream invocation during export.
set xsa_bit_tmp "${output_dir}/${output_basename}.tmp.bit"
file copy -force ${selected_bit} ${xsa_bit_tmp}
if {[catch {exec zip -q -j -u ${xsa_tmp} ${xsa_bit_tmp}} zip_error]} {
    file delete -force ${xsa_bit_tmp}
    error "failed to embed selected bitstream in XSA: ${zip_error}"
}
file delete -force ${xsa_bit_tmp}

if {[file exists ${xsa_tmp}]} {
    file rename -force ${xsa_tmp} ${xsa_file}
}

if {[file exists ${xsa_file}]} {
    rf2_identity_embed_manifest ${xsa_file} ${manifest_file}
    rf2_identity_verify_xsa_bit ${xsa_file} ${selected_bit}
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
