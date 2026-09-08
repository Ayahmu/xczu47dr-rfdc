set script_path [file dirname [file normalize [info script]]]
source $script_path/check_tdc_physical.tcl
if {$argc != 3} {error "Usage: resume_tdc_incremental.tcl current.dcp reference.dcp impl_directory"}
set current [file normalize [lindex $argv 0]]
set reference [file normalize [lindex $argv 1]]
set output [file normalize [lindex $argv 2]]
if {![file exists $current] || ![file exists $reference] || ![file isdirectory $output]} {
    error "Missing checkpoint or implementation directory"
}
open_checkpoint $current
# RuntimeOptimized inherits a potentially negative reference WNS. Signoff
# requires zero negative slack, so incremental retries must target closure.
read_checkpoint -incremental -directive TimingClosure $reference
place_design
phys_opt_design
route_design
write_checkpoint -force $output/TopCustomXczu47dr_routed.dcp
phys_opt_design -directive AggressiveExplore
write_checkpoint -force $output/TopCustomXczu47dr_postroute_physopt.dcp
report_timing_summary -delay_type min_max -report_unconstrained -file $output/tdc_final_timing.rpt
report_route_status -file $output/tdc_final_route.rpt
report_drc -ruledeck bitstream_checks -file $output/tdc_final_drc.rpt
check_tdc_physical
puts TDC_INCREMENTAL_RESUME_COMPLETE
close_design
