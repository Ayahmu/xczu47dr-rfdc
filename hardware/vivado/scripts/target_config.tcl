# Vivado target matrix for supported RFDC builds

proc target_config_allowed_targets {} {
    return [list zcu216 custom_xczu47dr]
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
        zcu216 {
            return [dict create                 target zcu216                 project_basename zcu216_rfdc                 part xczu49dr-ffvf1760-2-e                 part_query xczu49dr-ffvf1760-2-e                 board_part xilinx.com:zcu216:part0:2.0                 xdc_files [list xdc/pin.xdc]                 top_module Top                 output_basename zcu216_rfdc                 firmware_workspace firmware/workspace                 firmware_app rfdc_app                 firmware_elf firmware/workspace/rfdc_app/Debug/rfdc_app.elf                 psu_init firmware/workspace/hw_platform/hw/psu_init.tcl                 clock_policy zcu216_clk104_lmk_lmx]
        }
        custom_xczu47dr {
            return [dict create                 target custom_xczu47dr                 project_basename custom_xczu47dr_rfdc                 part xczu47dr-ffvg1517-2-i                 part_query *xczu47dr*ffvg1517*                 board_part {}                 xdc_files [list xdc/custom_xczu47dr_minimal.xdc]                 top_module TopCustomXczu47dr                 output_basename custom_xczu47dr_rfdc                 firmware_workspace firmware/workspace/custom_xczu47dr                 firmware_app rfdc_app                 firmware_elf firmware/workspace/custom_xczu47dr/rfdc_app/Debug/rfdc_app.elf                 psu_init firmware/workspace/custom_xczu47dr/hw_platform/hw/psu_init.tcl                 clock_policy custom_external_clock_decision_needed]
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
    foreach key [list project_basename part part_query board_part xdc_files top_module output_basename firmware_workspace firmware_app firmware_elf psu_init clock_policy] {
        puts "${key}: [dict get $cfg $key]"
    }
}

if {[info exists argv0] && [file normalize [info script]] eq [file normalize $argv0]} {
    set target zcu216
    if {[llength $argv] > 0} {
        set target [lindex $argv 0]
    }
    target_config_print $target
}
