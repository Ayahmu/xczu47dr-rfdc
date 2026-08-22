# Restore the reference bitstream-capable XXV Ethernet DCP for custom XCZU47DR.
# Vivado can regenerate this IP as Design_Linking-only, which later blocks write_bitstream.
#
# The XCI checked into the repository keeps its generated products below
# <project>/work/ip.  That path is deliberately derived from proj_dir so the
# master and slave builds never share the checkpoint or an IP lock.
proc restore_reference_xxv_dcp {vivado_dir proj_dir target {project_name ""}} {
    if {[string first "custom_xczu47dr" $target] != 0 || $target eq "custom_xczu47dr_bw"} {
        return
    }

    if {[info exists ::env(XXV_REFERENCE_DCP)] && $::env(XXV_REFERENCE_DCP) ne ""} {
        set ref_dcp [file normalize $::env(XXV_REFERENCE_DCP)]
    } else {
        set ref_dcp [file normalize "${vivado_dir}/../../../fpga_rfsoc_zjdx_20260503_jiaofu/test/test.gen/sources_1/ip/xxv_ethernet/xxv_ethernet.dcp"]
    }
    set local_dcp [file normalize "${proj_dir}/work/ip/xxv_ethernet_1/xxv_ethernet.dcp"]

    if {![file exists ${ref_dcp}]} {
        puts "ERROR: Reference XXV Ethernet DCP not found: ${ref_dcp}"
        puts "ERROR: Set XXV_REFERENCE_DCP to a bitstream-capable xxv_ethernet.dcp."
        exit 1
    }

    file mkdir [file dirname ${local_dcp}]
    set local_tmp "${local_dcp}.tmp"
    file delete -force ${local_tmp}
    file copy -force ${ref_dcp} ${local_tmp}
    file rename -force ${local_tmp} ${local_dcp}
    puts "INFO: Restored reference XXV Ethernet DCP: ${local_dcp}"

    # Keep the OOC run output in sync as well.  If Vivado decides that the
    # child run is already complete, it may use this copy instead of the IP
    # output directory copy during top-level synthesis.
    if {$project_name ne ""} {
        set ooc_dcp [file normalize "${proj_dir}/${project_name}.runs/xxv_ethernet_synth_1/xxv_ethernet.dcp"]
        file mkdir [file dirname ${ooc_dcp}]
        set ooc_tmp "${ooc_dcp}.tmp"
        file delete -force ${ooc_tmp}
        file copy -force ${ref_dcp} ${ooc_tmp}
        file rename -force ${ooc_tmp} ${ooc_dcp}
        puts "INFO: Restored reference XXV Ethernet OOC DCP: ${ooc_dcp}"

        # Vivado uses this marker when an OOC checkpoint was imported from
        # cache.  Marking the injected reference run complete prevents
        # launch_runs synth_1 from scheduling a Design_Linking-only rebuild.
        set marker [file join [file dirname ${ooc_dcp}] __synthesis_is_complete__]
        set marker_tmp "${marker}.tmp"
        set marker_fh [open ${marker_tmp} w]
        puts ${marker_fh} "Reference XXV Ethernet checkpoint"
        close ${marker_fh}
        file rename -force ${marker_tmp} ${marker}
    }
}

# Prepare the managed OOC run without executing protected XXV RTL.  The
# scripts-only step creates the run metadata; the checkpoint and completion
# marker are then restored so the parent synthesis run consumes the reference
# checkpoint directly.
proc prepare_reference_xxv_ooc_run {vivado_dir proj_dir target project_name} {
    if {[string first "custom_xczu47dr" $target] != 0 || $target eq "custom_xczu47dr_bw"} {
        return
    }

    set xxv_run [get_runs -quiet xxv_ethernet_synth_1]
    if {[llength ${xxv_run}] > 0} {
        set run_status [get_property STATUS ${xxv_run}]
        if {$run_status ne "synth_design Complete!" && [get_property PROGRESS ${xxv_run}] ne "100%"} {
            puts "INFO: Generating XXV Ethernet OOC run metadata only (status=${run_status})"
            catch {launch_runs ${xxv_run} -scripts_only} scripts_error
            if {$scripts_error ne ""} {
                puts "INFO: XXV OOC scripts-only preparation returned: ${scripts_error}"
            }
        }
    } else {
        puts "WARN: XXV Ethernet OOC run is not present; parent synthesis may compile protected RTL"
    }

    restore_reference_xxv_dcp ${vivado_dir} ${proj_dir} ${target} ${project_name}
}
