set script_path [file dirname [file normalize [info script]]]
source ${script_path}/target_config.tcl
source ${script_path}/check_tdc_physical.tcl
set target [lindex $argv 0]
if {![target_config_exists $target]} {target_config_error $target}
set project_name [target_config_get $target project_basename]
set output_name [target_config_get $target output_basename]
set output $::env(VIVADO_OUTPUT_DIR)
file mkdir $output
file delete -force $output/verification.json
set impl_dir $::env(VIVADO_WORK_DIR)/${project_name}.runs/impl_1
set dcp $impl_dir/TopCustomXczu47dr_postroute_physopt.dcp
if {![file exists $dcp]} {set dcp $impl_dir/TopCustomXczu47dr_routed.dcp}
set bit $impl_dir/$project_name.bit
set synth $::env(VIVADO_WORK_DIR)/${project_name}.runs/synth_1/TopCustomXczu47dr.dcp
if {![file exists $dcp] || ![file exists $synth] || [file mtime $dcp] < [file mtime $synth]} {
    error "Missing or stale implemented TDC checkpoint"
}
open_checkpoint $dcp
check_tdc_physical
set read_reset_cells [get_cells -hier -filter {NAME =~ top_i/u_tdc_events/rd_reset_sync_reg* && IS_SEQUENTIAL}]
if {[llength $read_reset_cells] != 3} {error "FIFO read reset synchronizer is missing"}
foreach cell $read_reset_cells {
    set clocks [get_clocks -of_objects [get_pins $cell/C]]
    if {![get_property ASYNC_REG $cell] || [llength $clocks] != 1 ||
        abs([get_property PERIOD $clocks] - 20.0) > 0.001} {
        error "FIFO read reset does not release in the 50 MHz DAC domain"
    }
}
foreach {primitive expected} {GTYE4_CHANNEL GTYE4_CHANNEL_X0Y8 GTYE4_COMMON GTYE4_COMMON_X0Y2} {
    set cells [get_cells -hier -filter "REF_NAME == $primitive && NAME =~ top_i/udp_10g_i/DUT/*"]
    if {[llength $cells] != 1 || [get_property LOC $cells] ne $expected} {
        error "Implemented SFP $primitive does not match board site $expected"
    }
}
foreach {port expected} {sfp_rxp N38 sfp_rxn N39 sfp_txp P35 sfp_txn P36 sfp_refclkp W33 sfp_refclkn W34} {
    if {[get_property PACKAGE_PIN [get_ports $port]] ne $expected} {
        error "Implemented SFP pin $port does not match board pin $expected"
    }
}
report_methodology -checks [get_methodology_checks TIMING-17] -file $output/${output_name}_clock_coverage.rpt
set coverage_file [open $output/${output_name}_clock_coverage.rpt r]
set coverage_text [read $coverage_file]
close $coverage_file
if {![regexp {Checks found:\s*0\s} $coverage_text]} {error "Unclocked sequential cells remain"}
report_timing_summary -delay_type min_max -report_unconstrained -file $output/${output_name}_timing.rpt
report_drc -ruledeck bitstream_checks -file $output/${output_name}_drc.rpt
report_utilization -file $output/${output_name}_utilization.rpt
report_clock_interaction -file $output/${output_name}_clock_interaction.rpt
report_cdc -file $output/${output_name}_cdc.rpt
# Bus-skew constraints are independent of setup/hold and false paths. Require
# a worst-path result for every applied constraint, as well as no violations.
set timing_xdc $impl_dir/tdc_export_timing.xdc
write_xdc -force -type timing -constraints VALID $timing_xdc
set constraints_file [open $timing_xdc r]
set constraints_text [read $constraints_file]
close $constraints_file
set bus_constraint_count [regexp -all -line {^\s*set_bus_skew\s} $constraints_text]
if {$bus_constraint_count == 0} {error "Expected XPM CDC bus-skew constraints are missing"}
set critical_before [get_msg_config -count -severity {CRITICAL WARNING}]
set bus_skew_text [report_bus_skew -delay_type min_max -warn_on_violation -return_string]
set bus_skew_file [open $output/${output_name}_bus_skew.rpt w]
puts -nonewline $bus_skew_file $bus_skew_text
close $bus_skew_file
if {[get_msg_config -count -severity {CRITICAL WARNING}] > $critical_before ||
    [regexp -nocase {\mVIOLATED\M} $bus_skew_text]} {
    error "Final checkpoint violates bus-skew constraints"
}
 # Vivado 2024.2 emits one "Slack (MET)" block per constraint and does not
 # emit a standalone Slack: line in the summary table. Count those status
 # blocks; any VIOLATED status is rejected above.
set bus_slack_count [regexp -all {Slack \(MET\)\s*:} $bus_skew_text]
if {[regexp -nocase {Slack \(VIOLATED\)\s*:} $bus_skew_text]} {
    error "Final checkpoint has negative bus-skew slack"
}
if {$bus_slack_count < $bus_constraint_count} {
    error "Incomplete bus-skew results: $bus_slack_count slacks for $bus_constraint_count constraints"
}
set timing_file [open $output/${output_name}_timing.rpt r]
set timing_text [read $timing_file]
close $timing_file
if {![string match {*All user specified timing constraints are met*} $timing_text]} {
    error "Timing summary does not certify all setup, hold and pulse-width constraints"
}
if {[llength [get_timing_paths -quiet -delay_type max -slack_lesser_than 0 -max_paths 1]] ||
    [llength [get_timing_paths -quiet -delay_type min -slack_lesser_than 0 -max_paths 1]]} {
    error "Final checkpoint does not meet setup/hold timing"
}
if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == {Critical Warning}}]]} {
    error "Final checkpoint has blocking DRC violations"
}
set setup_path [get_timing_paths -quiet -delay_type max -max_paths 1]
set hold_path [get_timing_paths -quiet -delay_type min -max_paths 1]
if {[llength $setup_path] != 1 || [llength $hold_path] != 1} {error "Missing timing paths"}
set wns [get_property SLACK $setup_path]
set whs [get_property SLACK $hold_path]
set sampling_clock [get_clocks -of_objects [get_pins -hier -filter {NAME == top_i/u_tdc_capture/sample_bit[0].u_sample_ff/C}]]
if {[llength $sampling_clock] != 1 || abs([get_property PERIOD $sampling_clock] - 5.0) > 0.001} {
    error "TDC sampling clock is not constrained to 200 MHz"
}
set route [report_route_status -return_string]
set route_file [open $output/${output_name}_route.rpt w]
puts -nonewline $route_file $route
close $route_file
if {[regexp -nocase {(?:unrouted nets|partially routed nets|nets with routing errors|nodes with overlaps)[^:\n]*:\s*([1-9][0-9]*)} $route]} {
    error "Unrouted or conflicting routing remains"
}
set calibration_source [get_pins -hier -filter {NAME == top_i/u_tdc_registers/control_reg[1]/Q}]
foreach {tap label} {0 first 2047 last} {
    set pin_name [format {top_i/u_tdc_capture/sample_bit[%d].u_sample_ff/D} $tap]
    set endpoint [get_pins -hier -filter "NAME == $pin_name"]
    report_timing -user_ignored -from $calibration_source -to $endpoint -delay_type min -max_paths 1 -file $output/${output_name}_tdc_${label}_fast.rpt
}
write_debug_probes -force $output/${output_name}.ltx
write_bitstream -force $bit
file copy -force $bit $output/${output_name}.bit.tmp
file rename -force $output/${output_name}.bit.tmp $output/${output_name}.bit
set verification [open $output/verification.json w]
set bit_sha256 [lindex [exec sha256sum -- $output/${output_name}.bit] 0]
set ltx_sha256 [lindex [exec sha256sum -- $output/${output_name}.ltx] 0]
set checkpoint_sha256 [lindex [exec sha256sum -- $dcp] 0]
puts $verification [format {{"schema":2,"target":"%s","setup_hold_passed":true,"all_timing_constraints_met":true,"wns_ns":%.6f,"whs_ns":%.6f,"carry8_count":256,"sampling_ff_count":2048,"sampling_period_ns":5.0,"blocking_drc_count":0,"clock_coverage_passed":true,"bus_skew_passed":true,"bus_skew_constraint_count":%d,"bus_skew_result_count":%d,"bit_sha256":"%s","ltx_sha256":"%s","checkpoint_sha256":"%s","analog_jitter_verified":false}} $target $wns $whs $bus_constraint_count $bus_slack_count $bit_sha256 $ltx_sha256 $checkpoint_sha256]
close $verification
puts "TDC_ARTIFACTS_EXPORTED $output/${output_name}.bit"
close_design
