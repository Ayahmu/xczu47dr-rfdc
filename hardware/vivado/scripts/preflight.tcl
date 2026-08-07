# RTL elaboration and structural checks that intentionally stop before synthesis.

set script_path [file dirname [file normalize [info script]]]
set vivado_dir [file dirname $script_path]
source "${script_path}/target_config.tcl"

set target "custom_xczu47dr"
if {$argc > 0} {
    set target [lindex $argv 0]
}
if {![target_config_exists $target]} {
    target_config_error $target
}

set proj_name [target_config_get $target project_basename]
set proj_file "${vivado_dir}/work/${proj_name}.xpr"
set target_part [target_config_get $target part]
set target_top [target_config_get $target top_module]
set report_dir "${vivado_dir}/reports/${target}"

if {![file exists $proj_file]} {
    error "Missing Vivado project: ${proj_file}. Run make vivado-project first."
}
file mkdir $report_dir

puts "INFO: Opening ${proj_file}"
open_project $proj_file
set preflight_stub_files [list]
set preflight_bd_files [list]

# RTL elaboration still needs the generated HDL wrappers for standalone IP.
# Generating output products here is much cheaper than launching OOC synthesis.
foreach ip_name {axis_async_fifo_256 axi_datamover_0 axis_data_fifo_1} {
    set ip [get_ips -quiet $ip_name]
    if {[llength $ip] == 0} {
        error "Missing required standalone IP: ${ip_name}"
    }
    puts "INFO: Ensuring output products exist for ${ip_name}"
    generate_target all $ip
}

# Block Design child IP normally uses OOC checkpoints.  synth_design -rtl does
# not read those checkpoints, so expose the generated HDL for this preflight.
foreach bd_name {design_1 ddr_axi_smartconnect} {
    set bd_file [get_files -quiet "*/bd/${bd_name}/${bd_name}.bd"]
    if {[llength $bd_file] == 0} {
        error "Missing required Block Design: ${bd_name}"
    }
    puts "INFO: Ensuring Block Design output products exist for ${bd_name}"
    set_property synth_checkpoint_mode None $bd_file
    generate_target all $bd_file
    lappend preflight_bd_files $bd_file
}

# Project-level RFDC and DDR4 cores are synthesized OOC in the real build.
# Their generated stubs are sufficient here and still validate every top-level
# port name and width without elaborating the device primitives themselves.
foreach ip_name {rfdc_custom_xczu47dr_ip ddr_custom_xczu47dr_ip} {
    set stale_stub [file normalize "${vivado_dir}/ip/${ip_name}/${ip_name}_stub.v"]
    set stale_file [get_files -quiet -all $stale_stub]
    if {[llength $stale_file] > 0} {
        puts "INFO: Removing stale preflight source [file tail $stale_stub]"
        remove_files $stale_file
    }

    set generated_stub [file normalize "${vivado_dir}/ip/${ip_name}/${ip_name}_bmstub.v"]
    if {![file exists $generated_stub]} {
        error "Missing generated IP stub: ${generated_stub}"
    }
    set preflight_stub [file normalize "${report_dir}/${ip_name}_preflight_stub.v"]
    set old_preflight_file [get_files -quiet -all $preflight_stub]
    if {[llength $old_preflight_file] > 0} {
        remove_files $old_preflight_file
    }
    file copy -force $generated_stub $preflight_stub
    puts "INFO: Adding current preflight stub for ${ip_name}"
    add_files -norecurse $preflight_stub
    lappend preflight_stub_files $preflight_stub
}

foreach ip_name {ila_s_axi_01 ila_udp_ddr ila_dac_axis} {
    set ip [get_ips -quiet $ip_name]
    if {[llength $ip] == 0} {
        error "Missing required ILA IP: ${ip_name}"
    }
    generate_target all $ip
    set generated_stub [file normalize \
        "${vivado_dir}/work/${proj_name}.gen/sources_1/ip/${ip_name}/${ip_name}_bmstub.v"]
    if {![file exists $generated_stub]} {
        error "Missing generated ILA stub: ${generated_stub}"
    }
    set preflight_stub [file normalize "${report_dir}/${ip_name}_preflight_stub.v"]
    set old_preflight_file [get_files -quiet -all $preflight_stub]
    if {[llength $old_preflight_file] > 0} {
        remove_files $old_preflight_file
    }
    file copy -force $generated_stub $preflight_stub
    puts "INFO: Adding current preflight stub for ${ip_name}"
    add_files -norecurse $preflight_stub
    lappend preflight_stub_files $preflight_stub
}

update_compile_order -fileset sources_1
report_compile_order -used_in synthesis -file "${report_dir}/preflight_compile_order.rpt"

puts "INFO: Elaborating ${target_top}; synthesis and implementation are not started"
set check_status [catch {
    synth_design -rtl -name rtl_preflight -top $target_top -part $target_part
    report_drc -ruledeck default -file "${report_dir}/preflight_drc.rpt"
    report_methodology -file "${report_dir}/preflight_methodology.rpt"
    set timing_note [open "${report_dir}/preflight_check_timing.rpt" w]
    puts $timing_note "Timing checks are deferred to the synthesized design; synth_design -rtl does not support check_timing."
    close $timing_note
} check_error check_options]

# Keep this helper from changing the project used by the real OOC build.
foreach stub_file $preflight_stub_files {
    set source_file [get_files -quiet -all $stub_file]
    if {[llength $source_file] > 0} {
        remove_files $source_file
    }
    file delete -force $stub_file
}
foreach bd_file $preflight_bd_files {
    set_property synth_checkpoint_mode Hierarchical $bd_file
}

if {$check_status != 0} {
    catch {close_design}
    close_project
    return -options $check_options $check_error
}

puts "INFO: RTL preflight complete"
close_design
close_project
