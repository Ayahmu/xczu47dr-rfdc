set repo [file normalize [file join [file dirname [info script]] ..]]
set result_dir [file join $repo work tdc_20260907 capture_physical]
file mkdir $result_dir
read_verilog [file join $repo hardware vivado src tdc_event_capture.v]
synth_design -top tdc_event_capture -part xczu47dr-ffvg1517-2-i -mode out_of_context -flatten_hierarchy none
create_clock -period 5.000 [get_ports sample_clk]
set carry_cells [get_cells -hier -filter {REF_NAME == CARRY8}]
set sample_cells [get_cells -hier -filter {NAME =~ sample_bit*.u_sample_ff}]
if {[llength $carry_cells] != 256 || [llength $sample_cells] != 2048} {
    error "Unexpected primitive count: carry=[llength $carry_cells] sample=[llength $sample_cells]"
}
for {set i 0} {$i < 256} {incr i} {
    set site SLICE_X50Y$i
    if {[llength [get_sites -quiet $site]] != 1} {error "Missing site $site"}
    set carry [get_cells [format {carry_block[%d].u_carry8} $i]]
    set_property LOC $site $carry
    set_property BEL CARRY8 $carry
    for {set b 0} {$b < 8} {incr b} {
        set sample [get_cells [format {sample_bit[%d].u_sample_ff} [expr {$i * 8 + $b}]]]
        set_property LOC $site $sample
        set_property BEL [string index ABCDEFGH $b]FF $sample
    }
}
opt_design
place_design
report_utilization -file [file join $result_dir utilization.rpt]
report_timing_summary -file [file join $result_dir timing_summary.rpt]
write_checkpoint -force [file join $result_dir placed.dcp]
puts "PASS: 256 CARRY8 and 2048 co-located sampling FFs placed on XCZU47DR"
