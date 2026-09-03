# Vivado target matrix for supported builds.

proc target_config_allowed_targets {} {
    return [list custom_xczu47dr_master custom_xczu47dr_slave \
                 custom_xczu47dr_slave_trigout custom_xczu47dr_bw]
}

proc target_config_exists {target} {
    expr {[lsearch -exact [target_config_allowed_targets] $target] >= 0}
}

proc target_config_error {target} {
    error "Unsupported TARGET=${target}. Allowed targets: [join [target_config_allowed_targets] {, }]"
}

proc target_config_load {target} {
    if {![target_config_exists $target]} {
        target_config_error $target
    }

    switch -- $target {
        custom_xczu47dr_master {
            return [dict create \
                target custom_xczu47dr_master \
                project_basename custom_xczu47dr_master_rfdc \
                part xczu47dr-ffvg1517-2-i \
                part_query *xczu47dr*ffvg1517* \
                board_part {} \
                xdc_files [list xdc/custom_xczu47dr_minimal.xdc xdc/custom_xczu47dr_master.xdc] \
                top_module TopCustomXczu47dr \
                output_basename custom_xczu47dr_master \
                firmware_workspace firmware/workspace/custom_xczu47dr_master \
                firmware_app rfdc_app \
                firmware_elf artifacts/custom_xczu47dr_master.elf \
                psu_init artifacts/custom_xczu47dr_master_psu_init.tcl \
                workspace_psu_init firmware/workspace/custom_xczu47dr_master/hw_platform/export/hw_platform/hw/psu_init.tcl \
                clock_policy external_10mhz_xs17 \
                generics {IS_MASTER=1}]
        }
        custom_xczu47dr_slave {
            return [dict create \
                target custom_xczu47dr_slave \
                project_basename custom_xczu47dr_slave_rfdc \
                part xczu47dr-ffvg1517-2-i \
                part_query *xczu47dr*ffvg1517* \
                board_part {} \
                xdc_files [list xdc/custom_xczu47dr_minimal.xdc xdc/custom_xczu47dr_slave.xdc] \
                top_module TopCustomXczu47dr \
                output_basename custom_xczu47dr_slave \
                firmware_workspace firmware/workspace/custom_xczu47dr_slave \
                firmware_app rfdc_app \
                firmware_elf artifacts/custom_xczu47dr_slave.elf \
                psu_init artifacts/custom_xczu47dr_slave_psu_init.tcl \
                workspace_psu_init firmware/workspace/custom_xczu47dr_slave/hw_platform/export/hw_platform/hw/psu_init.tcl \
                clock_policy external_10mhz_xs17 \
                generics {IS_MASTER=0}]
        }
        custom_xczu47dr_slave_trigout {
            # Bench-measurement variant of the slave: XS20/TRIG_3 mirrors the
            # XS18 Trigger output instead of carrying SYNC, so one board can
            # loop XS18->XS19 and still give the scope a Trigger reference.
            # Bypass mode only - this build has no SYNC input.
            # PS side is identical to the plain slave, so it reuses that
            # firmware workspace, ELF and psu_init; only the PL differs.
            return [dict create \
                target custom_xczu47dr_slave_trigout \
                project_basename custom_xczu47dr_slave_trigout_rfdc \
                part xczu47dr-ffvg1517-2-i \
                part_query *xczu47dr*ffvg1517* \
                board_part {} \
                xdc_files [list xdc/custom_xczu47dr_minimal.xdc xdc/custom_xczu47dr_slave_trigout.xdc] \
                top_module TopCustomXczu47dr \
                output_basename custom_xczu47dr_slave_trigout \
                firmware_workspace firmware/workspace/custom_xczu47dr_slave \
                firmware_app rfdc_app \
                firmware_elf artifacts/custom_xczu47dr_slave.elf \
                psu_init artifacts/custom_xczu47dr_slave_psu_init.tcl \
                workspace_psu_init firmware/workspace/custom_xczu47dr_slave/hw_platform/export/hw_platform/hw/psu_init.tcl \
                clock_policy external_10mhz_xs17 \
                generics {IS_MASTER=0 XS20_TRIG_OUT=1 TRIG_EMIT_DAC=1}]
        }
        custom_xczu47dr_bw {
            return [dict create \
                target custom_xczu47dr_bw \
                project_basename custom_xczu47dr_bandwidth \
                part xczu47dr-ffvg1517-2-i \
                part_query *xczu47dr*ffvg1517* \
                board_part {} \
                xdc_files [list xdc/custom_xczu47dr_bandwidth.xdc] \
                top_module TopBandwidthXczu47dr \
                output_basename custom_xczu47dr_bandwidth \
                firmware_workspace firmware/workspace/custom_xczu47dr_bandwidth \
                firmware_app bandwidth_app \
                firmware_elf artifacts/custom_xczu47dr_bandwidth.elf \
                psu_init artifacts/custom_xczu47dr_bandwidth_psu_init.tcl \
                workspace_psu_init firmware/workspace/custom_xczu47dr_bandwidth/hw_platform/hw/psu_init.tcl \
                clock_policy ddr_bandwidth_interleaved_512b \
                generics {}]
        }
    }
}

proc target_config_get {target key} {
    set cfg [target_config_load $target]
    if {![dict exists $cfg $key]} {
        error "Target ${target} has no field ${key}"
    }
    return [dict get $cfg $key]
}

proc target_config_print {target} {
    set cfg [target_config_load $target]
    puts "target: ${target}"
    foreach key [list project_basename part part_query board_part xdc_files top_module output_basename firmware_workspace firmware_app firmware_elf psu_init workspace_psu_init clock_policy generics] {
        puts "${key}: [dict get $cfg $key]"
    }
}

if {[info exists argv0] && [file normalize [info script]] eq [file normalize $argv0]} {
    set target custom_xczu47dr_master
    if {[llength $argv] > 0} {
        set target [lindex $argv 0]
    }
    target_config_print $target
}
