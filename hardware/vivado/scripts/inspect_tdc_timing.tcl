set dcp [lindex $argv 0]
set output [lindex $argv 1]
file mkdir $output
open_checkpoint $dcp
report_timing -delay_type max -max_paths 30 -nworst 1 -file $output/setup_paths.rpt
report_timing -delay_type min -max_paths 15 -nworst 1 -file $output/hold_paths.rpt
report_timing_summary -delay_type min_max -file $output/summary.rpt
puts "TDC_TIMING_INSPECTION_COMPLETE"
close_design
