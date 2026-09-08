proc check_tdc_physical {} {
    set carry_count 0
    set sample_count 0
    for {set i 0} {$i < 256} {incr i} {
        set name [format {top_i/u_tdc_capture/carry_block[%d].u_carry8} $i]
        set cell [get_cells -quiet -hier -filter "NAME == $name"]
        if {[llength $cell] != 1} {error "Missing TDC carry $name"}
        set expected SLICE_X50Y$i
        if {[get_property LOC $cell] ne $expected || [lindex [split [get_property BEL $cell] .] end] ne "CARRY8"} {
            error "TDC carry placement mismatch: $name"
        }
        incr carry_count
        for {set b 0} {$b < 8} {incr b} {
            set name [format {top_i/u_tdc_capture/sample_bit[%d].u_sample_ff} [expr {$i*8+$b}]]
            set cell [get_cells -quiet -hier -filter "NAME == $name"]
            set expected_bel [string index ABCDEFGH $b]FF
            if {[llength $cell] != 1 || [get_property LOC $cell] ne $expected ||
                [lindex [split [get_property BEL $cell] .] end] ne $expected_bel} {
                error "TDC capture FF placement mismatch: $name"
            }
            incr sample_count
        }
    }
    puts "TDC_PHYSICAL_PASS carries=$carry_count colocated_capture_ffs=$sample_count"
}
