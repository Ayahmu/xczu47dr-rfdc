#!/usr/bin/env xsct
# Program FPGA and Download ELF
# Usage: xsct program.tcl <bit_file> <elf_file> [psu_init_tcl]
# Set DRY_RUN=1 to print resolved paths without connecting to hardware.

if {$argc < 2 || $argc > 3} {
    puts "Usage: xsct program.tcl <bit_file> <elf_file> \[psu_init_tcl\]"
    puts "Example: xsct program.tcl ../artifacts/custom_xczu47dr_master.bit ../artifacts/custom_xczu47dr_master.elf ../artifacts/custom_xczu47dr_master_psu_init.tcl"
    exit 1
}

set bit_file [file normalize [lindex $argv 0]]
set elf_file [file normalize [lindex $argv 1]]
set script_dir [file dirname [file normalize [info script]]]
set firmware_dir [file normalize [file join $script_dir ".."]]
set target custom_xczu47dr_master
set download_elf_only 0
if {[info exists ::env(DOWNLOAD_ELF_ONLY)] && $::env(DOWNLOAD_ELF_ONLY) eq "1"} {
    set download_elf_only 1
}
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
    # jtag_cable_serial is a property of the level-0 JTAG cable target.  It is
    # not a reliable property on the nested PSU/TAP/A53 debug targets, and
    # applying it here makes otherwise valid debug targets disappear.
    # Cable selection is handled explicitly by select_board_cable.
    switch -- $role {
        psu { set role_filter {name =~ "PSU"} }
        fpga { set role_filter {name =~ "PS TAP"} }
        pl { set role_filter {name =~ "PL"} }
        a53 { set role_filter {name =~ "Cortex-A53 #0"} }
        dap { set role_filter {name =~ "DAP*"} }
        default { error "Unknown target role: $role" }
    }
    # targets is global even after selecting a level-0 JTAG cable.  Include
    # the cable serial so two simultaneously connected boards cannot match
    # each other's nested PSU/FPGA/A53 targets.
    if {[info exists ::env(JTAG_CABLE_SERIAL)] && $::env(JTAG_CABLE_SERIAL) ne ""} {
        set serial_filter "jtag_cable_serial == \"$::env(JTAG_CABLE_SERIAL)\""
        return "$serial_filter && $role_filter"
    }
    return $role_filter
}

proc board_cable_filter {target} {
    if {[info exists ::env(JTAG_CABLE_SERIAL)] && $::env(JTAG_CABLE_SERIAL) ne ""} {
        # level==0 is important: without it a serial match also returns every
        # nested target carrying the inherited cable property.
        return "jtag_cable_serial == \"$::env(JTAG_CABLE_SERIAL)\" && level == 0"
    }
    return {level == 0}
}

proc select_board_cable {target} {
    set filter [board_cable_filter $target]
    if {[catch {set matches [jtag targets -filter $filter]} err] || [string trim $matches] eq ""} {
        error "No JTAG cable matched ${filter}: ${err}"
    }
    if {[catch {jtag targets -set -filter $filter} err]} {
        error "Could not select JTAG cable using ${filter}: ${err}"
    }
}

proc board_role_filter {role} {
    switch -- $role {
        psu { return {name =~ "PSU"} }
        fpga { return {name =~ "PS TAP"} }
        pl { return {name =~ "PL"} }
        a53 { return {name =~ "Cortex-A53 #0"} }
        dap { return {name =~ "DAP*"} }
        default { error "Unknown target role: $role" }
    }
}

proc board_target_available {target role} {
    if {[catch {select_board_cable $target}]} {
        return 0
    }
    set filter [board_target_filter $target $role]
    if {[catch {set matches [targets -filter $filter]}]} {
        return 0
    }
    return [expr {[string trim $matches] ne ""}]
}

proc select_board_target {target role} {
    select_board_cable $target
    set filter [board_target_filter $target $role]
    if {[catch {set matches [targets -filter $filter]} err] || [string trim $matches] eq ""} {
        set serial "default"
        if {[info exists ::env(JTAG_CABLE_SERIAL)]} {
            set serial $::env(JTAG_CABLE_SERIAL)
        }
        puts "ERROR: Could not select JTAG cable ${serial} for role=${role}."
        puts "ERROR: The cable may be disconnected, the board may have no JTAG device, or another Vivado/XSCT process may own it."
        puts "Available debug targets:"
        targets
        if {$err ne ""} {
            error $err
        }
        error "No debug target matched ${filter}"
    }
    if {[catch {targets -set -filter $filter -timeout 15} err]} {
        puts "ERROR: JTAG target matched but could not be selected for role=${role}: ${err}"
        puts "ERROR: Close any Vivado/ILA or XSCT session currently controlling this board."
        error $err
    }
}

proc recover_psu_target {target} {
    if {[board_target_available $target psu]} {
        return
    }
    puts "PSU target is not visible yet; attempting JTAG recovery reset."
    foreach role {dap fpga} {
        if {![board_target_available $target $role]} {
            continue
        }
        if {[catch {select_board_target $target $role} err]} {
            puts "WARNING: could not select ${role} for recovery: ${err}"
            continue
        }
        if {$role eq "dap"} {
            catch {rst -system} reset_error
        } else {
            catch {rst -srst} reset_error
        }
        if {[info exists reset_error] && $reset_error ne ""} {
            puts "WARNING: ${role} recovery reset reported: ${reset_error}"
        }
        after 3000
        if {[board_target_available $target psu]} {
            puts "PSU target recovered."
            return
        }
    }
}

if {![info exists ::env(DRY_RUN)] || $::env(DRY_RUN) ne "1"} {
if {!$download_elf_only && ![file exists $bit_file]} {
    puts "ERROR: bitstream not found: $bit_file"
    exit 1
}
if {![file exists $elf_file]} {
    puts "ERROR: ELF not found: $elf_file"
    exit 1
}
if {!$download_elf_only && ![file exists $psu_init_file]} {
    puts "ERROR: psu_init.tcl not found: $psu_init_file"
    puts "Run make firmware-create to regenerate it, or restore the checked-in artifacts/ file"
    exit 1
}
}

puts "=========================================="
if {$download_elf_only} {
    puts "Downloading ELF only (preserving FPGA bitstream)"
} else {
    puts "Programming FPGA"
}
puts "=========================================="
if {!$download_elf_only} {
    puts "BIT: ${bit_file}"
}
puts "ELF: ${elf_file}"
if {!$download_elf_only} {
    puts "PS init: ${psu_init_file}"
}
puts ""

if {[info exists ::env(DRY_RUN)] && $::env(DRY_RUN) eq "1"} {
    puts "DRY_RUN=1; skipping connect, reset, psu_init, fpga, dow, and con"
    exit 0
}

puts "Connecting to target..."
if {[info exists ::env(HW_SERVER_URL)] && $::env(HW_SERVER_URL) ne ""} {
    puts "Using hw_server ${::env(HW_SERVER_URL)}"
    connect -url $::env(HW_SERVER_URL)
} else {
    connect
}

puts "Opening JTAG cables..."
if {[catch {jtag targets -open} jtag_error]} {
    puts "ERROR: Unable to open JTAG cables: ${jtag_error}"
    puts "ERROR: Close competing Vivado/hw_server target sessions and verify the cable serial."
    exit 1
}

set jtag_inventory [jtag targets -verbose -target-properties]
set requested_serial ""
if {[info exists ::env(JTAG_CABLE_SERIAL)]} {
    set requested_serial $::env(JTAG_CABLE_SERIAL)
}
if {$requested_serial ne "" && [string first "jtag_cable_serial ${requested_serial}" $jtag_inventory] < 0} {
    puts "ERROR: JTAG cable serial ${requested_serial} is not present in the opened JTAG inventory."
    puts "Detected JTAG inventory:"
    puts $jtag_inventory
    exit 1
}

puts "Available targets for selected cable ${requested_serial}:"
targets

if {!$download_elf_only} {
    recover_psu_target $target

    puts "Resetting system..."
    select_board_target $target psu
    if {[catch {rst -system} reset_error]} {
        puts "WARNING: rst -system failed on selected PS target: ${reset_error}"
        puts "WARNING: Continuing with psu_init/fpga/dow; some XSCT target names such as PS TAP do not support system reset."
    }
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
}

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
