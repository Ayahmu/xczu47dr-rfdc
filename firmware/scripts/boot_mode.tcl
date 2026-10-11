#!/usr/bin/env xsct
# Restart the PS in a chosen boot mode without touching the mode pins.
# Usage: xsct boot_mode.tcl <jtag|qspi>
#
#   jtag  the BootROM stops and waits for the debugger; used before the QSPI
#         flash is written, so that an image already in it is not running
#   qspi  the BootROM loads BOOT.BIN from the QSPI flash, exactly as it does
#         at power-on when the mode pins select QSPI32
#
# CRL_APB.BOOT_MODE_USER (0xFF5E0200) overrides the pins for the following
# system resets: bits [15:12] carry the mode, bit 8 enables it.  The override
# is cleared by the next power-on reset.
# Set JTAG_CABLE_SERIAL when more than one cable is connected, HW_SERVER_URL
# for a remote hw_server and DRY_RUN=1 to print the action only.

set alt_boot_mode [dict create jtag 0x0100 qspi 0x2100]
set mode [lindex $argv 0]
if {$argc != 1 || ![dict exists $alt_boot_mode $mode]} {
    puts "Usage: xsct boot_mode.tcl <jtag|qspi>"
    exit 1
}
set value [dict get $alt_boot_mode $mode]

if {[info exists ::env(DRY_RUN)] && $::env(DRY_RUN) eq "1"} {
    puts "DRY_RUN=1; would write ${value} to BOOT_MODE_USER (0xFF5E0200) and reset the system"
    exit 0
}

proc board_filter {name} {
    set filter "name =~ \"${name}\""
    if {[info exists ::env(JTAG_CABLE_SERIAL)] && $::env(JTAG_CABLE_SERIAL) ne ""} {
        set filter "jtag_cable_serial == \"$::env(JTAG_CABLE_SERIAL)\" && ${filter}"
    }
    return $filter
}

if {[info exists ::env(HW_SERVER_URL)] && $::env(HW_SERVER_URL) ne ""} {
    connect -url $::env(HW_SERVER_URL)
} else {
    connect
}
catch {jtag targets -open}
if {[catch {targets -set -filter [board_filter "PSU"] -timeout 15} err]} {
    puts "ERROR: no PSU target matched [board_filter PSU]: ${err}"
    puts "Available debug targets:"
    targets
    exit 1
}

set pin_names [dict create 0 JTAG 1 QSPI24 2 QSPI32 3 SD0 5 SD1 6 eMMC 14 SD1-LS]
# BOOT_MODE_POR (0xFF5E0204) keeps what the pins said at power-on; the low
# bits of BOOT_MODE_USER show the mode in effect, override included.
set pins [expr {[mrd -value 0xFF5E0204] & 0xF}]
set pin_name [expr {[dict exists $pin_names $pins] ? [dict get $pin_names $pins] : "mode ${pins}"}]
puts "Boot mode pins: ${pin_name}"
puts "Restarting in ${mode} boot mode..."
mwr 0xFF5E0200 $value
rst -system
after 2000
if {$mode eq "qspi"} {
    # The debugger can leave the A53 halted at the reset vector.
    catch {targets -set -filter [board_filter "Cortex-A53 #0"] -timeout 15}
    catch {con}
    if {$pins != 2} {
        puts "NOTE: the mode pins select ${pin_name}; set them to QSPI32 for the board to boot from flash at power-on."
    }
}
disconnect
