# V1 module synthesis only; this is NOT top-level/route/CDC sign-off.
# vivado -mode batch -source tests/check_waveform_primitives.tcl -tclargs <report-dir>
if {$argc != 1} { error "expected one report directory" }
set root [file normalize [file join [file dirname [info script]] ..]]
set report_dir [file normalize [lindex $argv 0]]
file mkdir $report_dir
create_project -in_memory -part xczu47dr-ffvg1517-2-i
set_param general.maxThreads 8
set modules {waveform_playback_controller waveform_trigger_cdc waveform_upload_writer waveform_response_serializer waveform_ddr_reader waveform_dac_stream}
foreach module $modules {
    read_verilog [file join $root hardware vivado src ${module}.v]
}
foreach module $modules {
    synth_design -top $module -part xczu47dr-ffvg1517-2-i -mode out_of_context
    create_clock -name module_clk -period 3.333 [get_ports clk]
    report_utilization -file [file join $report_dir ${module}_utilization.rpt]
    report_timing_summary -file [file join $report_dir ${module}_synth_timing.rpt]
    if {[llength [get_cells -hier -filter {REF_NAME =~ LD*}]]} {
        error "unintended latch in $module"
    }
    if {$module eq "waveform_upload_writer"} {
        set count [llength [get_cells -hier -filter {REF_NAME =~ RAMB*}]]
        puts "WAVEFORM_PACKET_BRAM_COUNT=$count"
        if {$count < 4} {error "packet buffer did not infer its four synchronous BRAM banks"}
    }
    if {$module eq "waveform_trigger_cdc"} {
        if {[llength [get_cells -hier -filter {REF_NAME == FDPE}]] != 1} {
            error "trigger capture must map to exactly one async-preset FF"
        }
        set synchronizers [get_cells -hier -filter {ASYNC_REG == TRUE}]
        if {[llength $synchronizers] != 6} {error "missing trigger/level synchronizer stages"}
    }
    close_design
}
puts "PASS: waveform primitive synthesis, reset cells, and BRAM inference"
