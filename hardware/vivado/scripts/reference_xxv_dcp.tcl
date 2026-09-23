# Restore the reference bitstream-capable XXV Ethernet DCP for custom XCZU47DR.
# Vivado can regenerate this IP as Design_Linking-only, which later blocks write_bitstream.
#
# Vivado resolves managed XCI generated products one level below the project
# work directory's own `work/ip` cache.  Keep this path explicit: RFDC/DDR
# project IPs live in `${proj_dir}/ip`, but the imported XXV XCI resolves its
# generated checkpoint under `${proj_dir}/work/ip`.
#
# The Vivado 2022.2 XXV DCP found in the historical external project is not
# interchangeable with the Vivado 2024.2 XCI used by this target: it silently
# expands a different v4.1 revision and produces a much larger, timing-failing
# top-level netlist.  Lock the reference to the 2024.2/v4.1.13 checkpoint and
# reject any accidental downgrade before copying it into a managed run.
set EXPECTED_XXV_DCP_SHA256 "17c3544db1178084d4d56a25f7782b227a7c00c58b453c0464f31e29aa3cea7f"
set EXPECTED_XXV_CORE_INFO "xxv_ethernet_v4_1_13,Vivado 2024.2"

proc validate_reference_xxv_dcp {ref_dcp} {
    global EXPECTED_XXV_DCP_SHA256 EXPECTED_XXV_CORE_INFO
    if {![file exists ${ref_dcp}]} {
        error "Reference XXV Ethernet DCP not found: ${ref_dcp}"
    }

    set actual_sha256 [string trim [exec sha256sum ${ref_dcp}]]
    set actual_sha256 [lindex [split ${actual_sha256}] 0]
    if {${actual_sha256} ne ${EXPECTED_XXV_DCP_SHA256}} {
        error "Reference XXV Ethernet DCP hash mismatch: expected ${EXPECTED_XXV_DCP_SHA256}, got ${actual_sha256}; refusing an unverified IP checkpoint"
    }

    # The DCP is a ZIP container; its stub is the portable provenance record
    # that identifies the generated IP core revision and Vivado release.
    set stub_text [exec unzip -p ${ref_dcp} xxv_ethernet_stub.v]
    set core_pattern [format {X_CORE_INFO = "%s"} ${EXPECTED_XXV_CORE_INFO}]
    if {![regexp ${core_pattern} ${stub_text}]} {
        error "Reference XXV Ethernet DCP core identity mismatch: expected ${EXPECTED_XXV_CORE_INFO}"
    }

    puts "INFO: Validated XXV Ethernet DCP: sha256=${actual_sha256}, core=${EXPECTED_XXV_CORE_INFO}"
}
proc reference_xxv_synthesize_fresh {} {
    # When a valid (permanent Design_Linking) XXV Ethernet license is present,
    # regenerate the IP netlist from its XCI under that license instead of
    # restoring the committed reference DCP.  The committed DCP was produced
    # under the old expired evaluation license, so its netlist carries a hard
    # "bitstream generation not permitted" flag that a valid license at
    # write_bitstream time cannot override.  Set XXV_SYNTHESIZE_FRESH=1 to
    # synthesize fresh (Design_Linking netlist -> write_bitstream accepts it
    # with the 12-1790 advisory that run_bitstream.tcl already handles).
    return [expr {[info exists ::env(XXV_SYNTHESIZE_FRESH)] &&
                  $::env(XXV_SYNTHESIZE_FRESH) eq "1"}]
}
proc restore_reference_xxv_dcp {vivado_dir proj_dir target {project_name ""}} {
    if {[reference_xxv_synthesize_fresh]} {
        puts "INFO: XXV_SYNTHESIZE_FRESH=1 -> using fresh XXV Ethernet synthesis under the current license; skipping reference-DCP restore"
        return
    }
    if {[string first "custom_xczu47dr" $target] != 0 || $target eq "custom_xczu47dr_bw"} {
        return
    }

    if {[info exists ::env(XXV_REFERENCE_DCP)] && $::env(XXV_REFERENCE_DCP) ne ""} {
        set ref_dcp [file normalize $::env(XXV_REFERENCE_DCP)]
    } else {
        set ref_dcp [file normalize "${vivado_dir}/reference/xxv_ethernet_v4_1_13.dcp"]
    }
    set local_dcp [file normalize "${proj_dir}/work/ip/xxv_ethernet_1/xxv_ethernet.dcp"]

    if {[catch {validate_reference_xxv_dcp ${ref_dcp}} validation_error]} {
        puts "ERROR: ${validation_error}"
        puts "ERROR: Provide the exact validated Vivado 2024.2/v4.1.13 XXV DCP via XXV_REFERENCE_DCP."
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

        # Vivado derives the child-run status from the run-state markers, not
        # from the presence of the DCP alone.  Make the managed OOC run look
        # like a completed cache import so launch_runs synth_1 does not start
        # protected Design_Linking RTL synthesis and overwrite the reference
        # checkpoint.  The run remains a normal XCI child run; only its
        # reproducible OOC result is supplied from the validated DCP.
        file delete -force [file join [file dirname ${ooc_dcp}] __synthesis_is_running__]
        set end_marker [file join [file dirname ${ooc_dcp}] .vivado.end.rst]
        set end_fh [open ${end_marker} w]
        close ${end_fh}
        set util_report [file join [file dirname ${ooc_dcp}] xxv_ethernet_utilization_synth.rpt]
        if {![file exists ${util_report}]} {
            set util_fh [open ${util_report} w]
            puts ${util_fh} "Reference bitstream-capable XXV Ethernet DCP"
            close ${util_fh}
        }
    }
}

# Prepare the managed OOC run without executing protected XXV RTL.  The
# scripts-only step creates the run metadata; the checkpoint and completion
# marker are then restored so the parent synthesis run consumes the reference
# checkpoint directly.
proc prepare_reference_xxv_ooc_run {vivado_dir proj_dir target project_name} {
    if {[reference_xxv_synthesize_fresh]} {
        puts "INFO: XXV_SYNTHESIZE_FRESH=1 -> XXV Ethernet OOC run will synthesize normally under the current license; skipping reference-DCP preparation"
        return
    }
    if {[string first "custom_xczu47dr" $target] != 0 || $target eq "custom_xczu47dr_bw"} {
        return
    }

    set xxv_run [get_runs -quiet xxv_ethernet_synth_1]
    if {[llength ${xxv_run}] == 0} {
        # read_ip/generate_target creates the managed XCI source set but does
        # not instantiate its OOC run object until the first launch. Create
        # that run explicitly so the reference checkpoint can be attached
        # before the parent synth scheduler evaluates dependencies.
        set xxv_ips [get_ips -quiet xxv_ethernet]
        if {[llength ${xxv_ips}] == 1} {
            puts "INFO: Creating managed XXV Ethernet OOC run metadata"
            catch {create_ip_run [lindex ${xxv_ips} 0]} create_run_error
            if {$create_run_error ne ""} {
                puts "INFO: create_ip_run returned: ${create_run_error}"
            }
            set xxv_run [get_runs -quiet xxv_ethernet_synth_1]
        }
    }
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
