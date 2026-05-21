#!/usr/bin/env xsct
# Program FPGA and Download ELF
# Usage: xsct program.tcl <bit_file> <elf_file> [psu_init_tcl]
# Set DRY_RUN=1 to print resolved paths without connecting to hardware.

if {$argc < 2 || $argc > 3} {
    puts "Usage: xsct program.tcl <bit_file> <elf_file> \[psu_init_tcl\]"
    puts "Example: xsct program.tcl ../hardware/vivado/output/<target>_rfdc.bit <target-workspace>/rfdc_app/Debug/rfdc_app.elf <target-workspace>/hw_platform/hw/psu_init.tcl"
    exit 1
}

set bit_file [file normalize [lindex $argv 0]]
set elf_file [file normalize [lindex $argv 1]]
set script_dir [file dirname [file normalize [info script]]]
set firmware_dir [file normalize [file join $script_dir ".."]]
set target zcu216
if {[info exists ::env(TARGET)]} {
    set target $::env(TARGET)
}

if {$argc == 3} {
    set psu_init_file [file normalize [lindex $argv 2]]
} else {
    set config_script [file normalize [file join $firmware_dir ".." "hardware" "vivado" "scripts" "target_config.tcl"]]
    source $config_script
    set project_root [file normalize [file join $firmware_dir ".."]]
    set psu_init_file [file normalize [file join $project_root [target_config_get $target psu_init]]]
}

proc board_target_filter {target role} {
    if {[info exists ::env(JTAG_CABLE_SERIAL)]} {
        set serial $::env(JTAG_CABLE_SERIAL)
    } elseif {$target eq "custom_xczu47dr"} {
        set serial "210512180081"
    } elseif {$target eq "zcu216"} {
        set serial "74243309093A"
    } else {
        set serial ""
    }

    switch -- $role {
        psu { set role_filter {name =~ "PSU"} }
        fpga { set role_filter {name =~ "PS TAP"} }
        pl { set role_filter {name =~ "PL"} }
        a53 { set role_filter {name =~ "Cortex-A53 #0"} }
        default { error "Unknown target role: $role" }
    }

    if {$serial eq ""} {
        return $role_filter
    }
    return "jtag_cable_serial == \"$serial\" && $role_filter"
}

proc select_board_target {target role} {
    set filter [board_target_filter $target $role]
    targets -set -filter $filter
}

if {![info exists ::env(DRY_RUN)] || $::env(DRY_RUN) ne "1"} {
if {![file exists $bit_file]} {
    puts "ERROR: bitstream not found: $bit_file"
    exit 1
}
if {![file exists $elf_file]} {
    puts "ERROR: ELF not found: $elf_file"
    exit 1
}
if {![file exists $psu_init_file]} {
    puts "ERROR: psu_init.tcl not found: $psu_init_file"
    puts "Run firmware platform creation first: make firmware-create or make firmware"
    exit 1
}
}

puts "=========================================="
puts "Programming FPGA"
puts "=========================================="
puts "BIT: ${bit_file}"
puts "ELF: ${elf_file}"
puts "PS init: ${psu_init_file}"
puts ""

if {[info exists ::env(DRY_RUN)] && $::env(DRY_RUN) eq "1"} {
    puts "DRY_RUN=1; skipping connect, reset, psu_init, fpga, dow, and con"
    exit 0
}

puts "Connecting to target..."
connect

puts "Available targets:"
targets

puts "Resetting system..."
select_board_target $target psu
rst -system
after 3000

puts "Initializing PS..."
source $psu_init_file

select_board_target $target psu
psu_init

puts "Programming FPGA..."
select_board_target $target fpga
fpga ${bit_file}

puts "Configuring PS-PL isolation and resets..."
select_board_target $target psu
psu_ps_pl_isolation_removal
psu_ps_pl_reset_config

puts "Downloading ELF to A53 #0..."
select_board_target $target a53
rst -processor
after 1000
dow ${elf_file}

puts "Starting execution..."
con

puts ""
puts "=========================================="
puts "Programming complete!"
puts "=========================================="
puts "Connect to UART at 115200 baud to see output"
