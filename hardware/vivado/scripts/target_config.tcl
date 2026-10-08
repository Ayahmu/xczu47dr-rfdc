# Vivado target configuration for the single-board waveform product.
#
# There is intentionally one production target.  Synchronization/master/slave
# playback variants were removed from the release flow; the Top parameter is
# kept only for the board clock initialization contract and is not a target
# selector.

proc target_config_allowed_targets {} {
    return [list custom_xczu47dr_waveform]
}

proc target_config_exists {target} {
    expr {[lsearch -exact [target_config_allowed_targets] $target] >= 0}
}

proc target_config_error {target} {
    error "Unsupported TARGET=${target}. Allowed target: custom_xczu47dr_waveform"
}

# External XS17 reference frequency, selected at build time via the
# REFERENCE_MHZ environment variable (default 250).  It drives the HMC7044 R1
# divider generic (250 MHz -> R1=25, 10 MHz -> R1=1); PLL1 always closes on a
# 10 MHz PFD so every downstream clock is identical for both profiles.
proc target_config_reference_mhz {} {
    set ref 250
    if {[info exists ::env(REFERENCE_MHZ)] && $::env(REFERENCE_MHZ) ne ""} {
        set ref $::env(REFERENCE_MHZ)
    }
    if {$ref ne "10" && $ref ne "250"} {
        error "REFERENCE_MHZ must be 10 or 250 (got '${ref}')"
    }
    return $ref
}

proc target_config_generics {} {
    return [list "REFERENCE_MHZ=[target_config_reference_mhz]"]
}

proc target_config_load {target} {
    if {![target_config_exists $target]} {
        target_config_error $target
    }

    return [dict create \
        target custom_xczu47dr_waveform \
        project_basename custom_xczu47dr_waveform_rfdc \
        part xczu47dr-ffvg1517-2-i \
        part_query *xczu47dr*ffvg1517* \
        board_part {} \
        xdc_files [list xdc/custom_xczu47dr_minimal.xdc constraints/tdc_placement.xdc constraints/tdc_timing.xdc] \
        top_module TopCustomXczu47dr \
        output_basename custom_xczu47dr_waveform \
        firmware_workspace firmware/workspace/custom_xczu47dr_waveform \
        firmware_app rfdc_app \
        firmware_elf artifacts/custom_xczu47dr_waveform.elf \
        workspace_psu_init firmware/workspace/custom_xczu47dr_waveform/hw_platform/hw/psu_init.tcl \
        clock_policy external_250mhz_xs17 \
        generics [target_config_generics]]
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
    foreach key [list project_basename part part_query board_part xdc_files top_module output_basename firmware_workspace firmware_app firmware_elf workspace_psu_init clock_policy generics] {
        puts "${key}: [dict get $cfg $key]"
    }
}

if {[info exists argv0] && [file normalize [info script]] eq [file normalize $argv0]} {
    set target custom_xczu47dr_waveform
    if {[llength $argv] > 0} {
        set target [lindex $argv 0]
    }
    target_config_print $target
}
