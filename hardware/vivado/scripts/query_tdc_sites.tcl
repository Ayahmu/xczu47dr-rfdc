if {$argc != 1} {
    puts "ERROR: usage: query_tdc_sites.tcl <synth.dcp>"
    exit 2
}

open_checkpoint [lindex $argv 0]
puts "TRIG_2_PORT=[get_ports -quiet TRIG_2]"
puts "TRIG_2_PACKAGE_PIN=[get_property PACKAGE_PIN [get_ports -quiet TRIG_2]]"
set carry_cells [get_cells -hier -filter {REF_NAME == CARRY8}]
puts "CARRY8_COUNT=[llength $carry_cells]"
foreach c [lsort -dictionary $carry_cells] {
    puts "CARRY8_CELL=$c REF=[get_property REF_NAME $c] LOC=[get_property LOC $c] BEL=[get_property BEL $c] DONT_TOUCH=[get_property DONT_TOUCH $c]"
}
set tdc_cells [get_cells -hier -filter {NAME =~ *tdc*}]
puts "TDC_CELL_COUNT=[llength $tdc_cells]"
foreach c [lsort -dictionary $tdc_cells] {
    puts "TDC_CELL=$c REF=[get_property REF_NAME $c]"
}
puts "SLICE_X50Y100=[get_sites -quiet SLICE_X50Y100]"
puts "SLICE_X50Y131=[get_sites -quiet SLICE_X50Y131]"
puts "SLICE_X50Y100_CLOCK_REGION=[get_property CLOCK_REGION [get_sites -quiet SLICE_X50Y100]]"
puts "SLICE_X50Y131_CLOCK_REGION=[get_property CLOCK_REGION [get_sites -quiet SLICE_X50Y131]]"
puts "SLICE_X50_COLUMN_COUNT=[llength [get_sites -quiet SLICE_X50Y*]]"
set x50_sites [get_sites -quiet -filter {SITE_TYPE =~ SLICE* && NAME =~ SLICE_X50Y*}]
foreach s [lsort -dictionary $x50_sites] {
    puts "X50_SITE=$s CLOCK_REGION=[get_property CLOCK_REGION $s] SITE_TYPE=[get_property SITE_TYPE $s]"
}
close_design
