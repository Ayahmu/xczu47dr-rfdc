# Vivado Bitstream Generation Script

set script_path [file dirname [file normalize [info script]]]
set vivado_dir [file dirname $script_path]
source "${script_path}/target_config.tcl"
source "${script_path}/reference_xxv_dcp.tcl"
source "${script_path}/build_options.tcl"
source "${script_path}/build_identity.tcl"

proc xxv_permanent_design_linking_license_enabled {} {
    if {![info exists ::env(XXV_ALLOW_DESIGN_LINKING_LICENSE)] ||
        $::env(XXV_ALLOW_DESIGN_LINKING_LICENSE) ne "1"} {
        return 0
    }
    if {![info exists ::env(XILINXD_LICENSE_FILE)] ||
        $::env(XILINXD_LICENSE_FILE) eq ""} {
        return 0
    }
    set required [list xxv_eth_mac_pcs xxv_eth_basekr xxv_tsn_802d1cm]
    set found [dict create]
    foreach license_file [split $::env(XILINXD_LICENSE_FILE) : ] {
        if {![file exists $license_file]} {
            continue
        }
        set fd [open $license_file r]
        set body [read $fd]
        close $fd
        foreach feature $required {
            if {[regexp -line "^INCREMENT ${feature} .* permanent" $body]} {
                dict set found $feature 1
            }
        }
    }
    foreach feature $required {
        if {![dict exists $found $feature]} {
            return 0
        }
    }
    return 1
}

set target "custom_xczu47dr_waveform"
if {$argc > 0} {
    set target [lindex $argv 0]
}
if {![target_config_exists $target]} {
    target_config_error $target
}

set proj_name [target_config_get $target project_basename]
set output_basename [target_config_get $target output_basename]
set proj_dir [expr {[info exists ::env(VIVADO_WORK_DIR)] ? $::env(VIVADO_WORK_DIR) : "${vivado_dir}/work"}]
set proj_file "${proj_dir}/${proj_name}.xpr"
set output_dir [expr {[info exists ::env(VIVADO_OUTPUT_DIR)] ? $::env(VIVADO_OUTPUT_DIR) : "${vivado_dir}/output"}]

puts "INFO: Opening project ${proj_file}"
open_project ${proj_file}
set manifest_file "${proj_dir}/build_manifest.json"
rf2_identity_validate_project ${manifest_file} ${target} ${script_path}

# The XXV Ethernet XCI remains enabled for implementation and bitstream
# generation. Its managed OOC checkpoint is resolved by impl_1; this flow does
# not replace the cell with a parent stub or copy a reference DCP.
set xxv_xci [get_files -quiet -all *xxv_ethernet.xci]
if {[llength ${xxv_xci}] != 1} {
    error "Expected exactly one managed XXV Ethernet XCI, found [llength ${xxv_xci}]"
}
set_property USED_IN_IMPLEMENTATION true ${xxv_xci}

# Restore the same bitstream-capable managed OOC checkpoint before launching
# write_bitstream. This is not a cell-level read_checkpoint replacement.
restore_reference_xxv_dcp ${vivado_dir} ${proj_dir} ${target} ${proj_name}

# Create output directory
file mkdir ${output_dir}

set impl_dir "${proj_dir}/${proj_name}.runs/impl_1"
set existing_bit_files [glob -nocomplain ${impl_dir}/*.bit]
set bit_generated 0
set valid_bit_files [list]
foreach candidate ${existing_bit_files} {
    set candidate_manifest "${candidate}.manifest.json"
    if {[file exists ${candidate_manifest}] &&
        ![catch {rf2_identity_validate_manifest ${candidate_manifest} ${target} ${script_path}}]} {
        lappend valid_bit_files ${candidate}
    }
}
if {[llength ${existing_bit_files}] == 0} {
    puts "INFO: Generating bitstream from the project-managed impl_1 run..."
    launch_runs impl_1 -to_step write_bitstream -jobs 8
    wait_on_run impl_1
    set bit_generated 1
} elseif {[llength ${valid_bit_files}] > 0} {
    puts "INFO: Reusing identity-checked bitstream: [lindex ${valid_bit_files} 0]"
} else {
    error "existing implementation bitstream has no matching build manifest; rerun implementation"
}

# Check bitstream generation status
if {${bit_generated} || [llength ${valid_bit_files}] == 0} {
    set bit_status [get_property STATUS [get_runs impl_1]]
    set bit_progress [get_property PROGRESS [get_runs impl_1]]

    puts "INFO: Bitstream status: ${bit_status}"
    puts "INFO: Bitstream progress: ${bit_progress}"

    if {${bit_progress} != "100%"} {
        puts "ERROR: Bitstream generation failed!"
        exit 1
    }

}

# A successful or reused bitgen result is not sufficient for release. Vivado
# may emit a configuration image while reporting a Critical Warning, notably
# when protected XXV Ethernet features run under an evaluation/design-linking
# license. Inspect the run log for both newly generated and reused images.
set bit_run_log [file join [get_property DIRECTORY [get_runs impl_1]] runme.log]
if {[file exists ${bit_run_log}]} {
    set bit_log_fh [open ${bit_run_log} r]
    set bit_log_body [read ${bit_log_fh}]
    close ${bit_log_fh}
    if {[regexp -line {CRITICAL WARNING:} ${bit_log_body}]} {
        # Vivado 2024.2 emits 12-1790 for the XXV design-linking IP even
        # when the license file is permanent.  Accept only this exact,
        # explicitly enabled license advisory; all other critical warnings
        # remain hard release failures.
        if {[regexp -line {Vivado 12-1790.*Evaluation License Warning} ${bit_log_body}] &&
            [xxv_permanent_design_linking_license_enabled]} {
            puts "WARNING: Accepted XXV 12-1790 advisory under permanent design-linking license"
        } else {
            error "Bitstream generation produced an unapproved Critical Warning; refusing release artifact"
        }
    }
}

# The bitstream is an intermediate input to XSA export.  Do not publish a
# second image or debug-probe file next to the XSA; the production artifact
# directory contains only XSA and ELF files.
set bit_file "${impl_dir}/*.bit"
set bit_files [glob -nocomplain ${bit_file}]
if {[llength $bit_files] == 0} {
    puts "ERROR: Bitstream file not found!"
    exit 1
}
set selected_bit [lindex ${bit_files} 0]
set selected_manifest "${selected_bit}.manifest.json"
if {![file exists ${selected_manifest}]} {
    if {${bit_generated}} {
        rf2_identity_stamp ${selected_bit} ${manifest_file}
    } else {
        error "bitstream is missing its build identity sidecar: ${selected_bit}"
    }
}
rf2_identity_validate_manifest ${selected_manifest} ${target} ${script_path}
puts "INFO: Bitstream generated internally for XSA export; no standalone image published"

set timing_rpt "${impl_dir}/TopCustomXczu47dr_timing_summary_postroute_physopted.rpt"
if {![file exists ${timing_rpt}]} {
    set timing_rpt "${impl_dir}/reports/post_impl_timing.rpt"
}
if {[file exists ${timing_rpt}]} {
    file copy -force ${timing_rpt} ${output_dir}/${output_basename}_timing.rpt
    puts "INFO: Timing report copied to ${output_dir}/${output_basename}_timing.rpt"
}

# Timing gate.  This design routes at level-5 congestion with only ~20% LUT use,
# so WNS swings across builds and has landed anywhere from -0.070 ns to
# +0.107 ns.  Nothing downstream checked it, which meant a bitstream that misses
# timing could be written into artifacts/ and flashed without anyone noticing.
# Abort instead, unless TIMING_GATE=0 is set in the environment.
set timing_gate [build_option_get TIMING_GATE 1]
set routed_rpt "${impl_dir}/TopCustomXczu47dr_timing_summary_routed.rpt"
if {${timing_gate} && [file exists ${routed_rpt}]} {
    set fh [open ${routed_rpt} r]
    set body [read ${fh}]
    close ${fh}
    if {[regexp {Timing constraints are not met} ${body}]} {
        set wns "?"
        if {[regexp -line {^\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+\d+\s+\d+} ${body} -> wns tns]} {}
        puts "ERROR: implementation does not meet timing (WNS=${wns} ns)."
        puts "       Refusing to publish ${output_basename}.bit - re-run implementation,"
        puts "       reduce ILA probe width/count, or override with TIMING_GATE=0."
        close_project
        exit 1
    }
    puts "INFO: Timing gate passed (all user specified timing constraints are met)"
}

puts "INFO: Bitstream generation complete"
close_project
