# Cell-level reference-DCP binding does not reliably retain the IP's scoped
# timing rules. Reapply the generated vendor constraints after binding.
proc restore_xxv_timing {proj_dir} {
    set root ${proj_dir}/work/ip/xxv_ethernet_1
    set dut [get_cells -quiet top_i/udp_10g_i/DUT]
    set gt [get_cells -quiet top_i/udp_10g_i/DUT/inst/i_xxv_ethernet_gt]
    if {[llength $dut] != 1 || [llength $gt] != 1} {error "XXV timing hierarchy is missing"}
    foreach path [list $root/synth/xxv_ethernet.xdc $root/ip_0/synth/xxv_ethernet_gt.xdc] {
        if {![file exists $path]} {error "Missing generated XXV timing constraints: $path"}
    }
    set locations [dict create]
    # The COMMON can be unplaced after cell-level DCP binding. These sites
    # follow the custom board's SFP pins (N38/P35 and W33), not the IP default.
    foreach {primitive board_loc} {
        GTYE4_CHANNEL GTYE4_CHANNEL_X0Y8
        GTYE4_COMMON GTYE4_COMMON_X0Y2
    } {
        set cells [get_cells -hier -filter "REF_NAME == $primitive && NAME =~ top_i/udp_10g_i/DUT/*"]
        if {[llength $cells] != 1} {error "Expected one SFP $primitive, found [llength $cells]"}
        set loc [get_property LOC $cells]
        if {$loc ne "" && $loc ne $board_loc} {
            error "Reference SFP $primitive LOC $loc conflicts with board site $board_loc"
        }
        dict set locations [get_property NAME $cells] $board_loc
    }
    read_xdc -cells $dut $root/synth/xxv_ethernet.xdc
    read_xdc -cells $gt $root/ip_0/synth/xxv_ethernet_gt.xdc
    # Restore board placement after the generated XDC's generic lane LOC.
    dict for {name loc} $locations {set_property LOC $loc [get_cells $name]}
    puts "XXV_TIMING_RESTORED"
}
