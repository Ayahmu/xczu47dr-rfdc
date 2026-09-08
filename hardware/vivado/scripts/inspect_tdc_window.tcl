set script_path [file dirname [file normalize [info script]]]
open_checkpoint [lindex $argv 0]
set output [lindex $argv 1]
file mkdir $output
set source [get_pins -hier -filter {NAME == top_i/u_tdc_registers/control_reg[1]/Q}]
set endpoint [get_pins -hier -filter {NAME == top_i/u_tdc_capture/sample_bit[2047].u_sample_ff/D}]
set entry [get_pins -hier -filter {NAME == top_i/u_tdc_capture/carry_block[0].u_carry8/CI}]
set captures [get_pins -hier -filter {NAME =~ top_i/u_tdc_capture/sample_bit*.u_sample_ff/D}]
report_timing -user_ignored -from $source -to $endpoint -delay_type min -max_paths 1 -file $output/window_fast.rpt
report_timing -user_ignored -from $source -to $endpoint -delay_type max -max_paths 1 -file $output/window_slow.rpt
set first [get_pins -hier -filter {NAME == top_i/u_tdc_capture/sample_bit[0].u_sample_ff/D}]
report_timing -user_ignored -from $source -to $first -delay_type min -max_paths 1 -file $output/first_tap_fast.rpt
if {[llength $entry] != 1 || [llength $captures] != 2048} {error "TDC timing endpoint mismatch"}
report_timing -delay_type max -max_paths 10 -nworst 1 -file $output/digital_setup.rpt
report_timing -delay_type min -max_paths 10 -nworst 1 -file $output/digital_hold.rpt
puts "TDC_WINDOW_INSPECTION_COMPLETE"
close_design
