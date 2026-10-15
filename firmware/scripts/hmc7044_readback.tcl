# Dump the HMC7044 register readback bank over JTAG while the firmware runs.
#
#   JTAG_CABLE_SERIAL=<serial> xsct firmware/scripts/hmc7044_readback.tcl
#
# Prints "STATUS 0x<word>" ({GPIO1, 15'b0, sweep count}) followed by one
# "REG 0x<addr> 0x<value>" line per HMC7044 register 0x00..0x9F; decode with
# firmware/scripts/hmc7044_decode.py.  The PL re-reads the bank continuously,
# so two dumps with different sweep counts prove the SPI readback is live.
set base 0xA0010000

proc board_filter {name} {
    set filter "name =~ \"${name}*\""
    if {[info exists ::env(JTAG_CABLE_SERIAL)]} {
        set filter "jtag_cable_serial == \"$::env(JTAG_CABLE_SERIAL)\" && ${filter}"
    }
    return $filter
}

if {[info exists ::env(HW_SERVER_URL)]} {
    connect -url $::env(HW_SERVER_URL)
} else {
    connect
}
catch {jtag targets -open}
targets -set -filter [board_filter "PSU"] -timeout 15

puts [format "STATUS 0x%08x" [mrd -force -value [expr {$base + 0x00C}]]]
for {set i 0} {$i < 40} {incr i} {
    set word [mrd -force -value [expr {$base + 0x100 + 4 * $i}]]
    for {set b 0} {$b < 4} {incr b} {
        puts [format "REG 0x%02x 0x%02x" [expr {4 * $i + $b}] [expr {($word >> (8 * $b)) & 0xFF}]]
    }
}
disconnect
