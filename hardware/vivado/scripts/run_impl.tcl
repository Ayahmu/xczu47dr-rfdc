# Vivado Implementation Script

set script_path [file dirname [file normalize [info script]]]
set vivado_dir [file dirname $script_path]
source "${script_path}/target_config.tcl"
source "${script_path}/reference_xxv_dcp.tcl"

proc ooc_run_complete {run_name} {
    set run_obj [get_runs -quiet $run_name]
    if {[llength $run_obj] == 0} {
        return 0
    }

    set status [get_property STATUS $run_obj]
    set progress [get_property PROGRESS $run_obj]
    if {$status eq "synth_design Complete!" || $progress eq "100%"} {
        return 1
    }

    # Vivado may import a valid OOC checkpoint from IP cache without changing
    # the run status from "Scripts Generated". Treat that as complete only
    # when the run directory contains both the synthesis marker and a DCP.
    if {$status eq "Scripts Generated"} {
        set run_dir [get_property DIRECTORY $run_obj]
        set complete_marker [file join $run_dir "__synthesis_is_complete__"]
        set dcp_files [glob -nocomplain -directory $run_dir *.dcp]
        if {[file exists $complete_marker] && [llength $dcp_files] > 0} {
            puts "INFO: OOC run ${run_name} completed from IP cache"
            return 1
        }
    }

    return 0
}

set target "custom_xczu47dr"
if {$argc > 0} {
    set target [lindex $argv 0]
}
if {![target_config_exists $target]} {
    target_config_error $target
}

set proj_name [target_config_get $target project_basename]
set proj_dir "${vivado_dir}/work"
set proj_file "${proj_dir}/${proj_name}.xpr"

puts "INFO: Opening project ${proj_file}"
open_project ${proj_file}

# Reuse the last successful routed design as the implementation reference.
# Keep this checkpoint outside impl_1 because reset_run removes the run
# directory contents before the next launch.
set incremental_dir "${vivado_dir}/work/incremental"
file mkdir ${incremental_dir}
set impl_incremental_checkpoint "${incremental_dir}/${proj_name}_impl.dcp"
set impl_run [get_runs -quiet impl_1]
if {[llength ${impl_run}] > 0 && [file exists ${impl_incremental_checkpoint}]} {
    #set_property INCREMENTAL_CHECKPOINT ${impl_incremental_checkpoint} ${impl_run}
    puts "INFO: Incremental implementation enabled with ${impl_incremental_checkpoint}"
} else {
    puts "INFO: No implementation checkpoint found; running a full implementation"
}

puts "INFO: Skipping XXV Ethernet OOC synthesis; using reference DCP"

#restore_reference_xxv_dcp ${vivado_dir} ${target}

set bd_file [get_files -quiet ${proj_dir}/${proj_name}.srcs/sources_1/bd/design_1/design_1.bd]
if {[llength ${bd_file}] > 0} {
    puts "INFO: Regenerating Block Design targets before implementation"
    generate_target all ${bd_file}

    set rfdc_runs [concat \
        [get_runs -quiet design_1_usp_rf_data_converter_0_0_synth_1] \
        [get_runs -quiet rfdc_custom_xczu47dr_ip_synth_1]]
    if {[llength ${rfdc_runs}] > 0} {
        puts "INFO: Ensuring RFDC OOC checkpoint is generated"
        foreach rfdc_run ${rfdc_runs} {
            reset_run ${rfdc_run}
            launch_runs ${rfdc_run} -jobs 8
            wait_on_run ${rfdc_run}

            set rfdc_status [get_property STATUS ${rfdc_run}]
            set rfdc_progress [get_property PROGRESS ${rfdc_run}]
            if {![ooc_run_complete ${rfdc_run}]} {
                puts "ERROR: RFDC OOC synthesis failed: ${rfdc_status}"
                exit 1
            }
        }
    } else {
        puts "INFO: No standalone RFDC OOC run found; relying on parent Block Design targets"
    }

    set ddr_runs [concat \
        [get_runs -quiet design_1_ddr4_0_0_synth_1] \
        [get_runs -quiet ddr_custom_xczu47dr_ip_synth_1]]
    if {[llength ${ddr_runs}] > 0} {
        puts "INFO: Ensuring DDR4 OOC checkpoint is generated"
        foreach ddr_run ${ddr_runs} {
            reset_run ${ddr_run}
            launch_runs ${ddr_run} -jobs 8
            wait_on_run ${ddr_run}

            set ddr_status [get_property STATUS ${ddr_run}]
            set ddr_progress [get_property PROGRESS ${ddr_run}]
            if {![ooc_run_complete ${ddr_run}]} {
                puts "ERROR: DDR4 OOC synthesis failed: ${ddr_status}"
                exit 1
            }
        }
    } else {
        puts "INFO: No standalone DDR4 OOC run found; relying on parent Block Design targets"
    }
}

puts "INFO: Starting implementation..."
set impl_run [get_runs impl_1]

# The 300 MHz DDR UI domain is close to the device routing limit. Run a
# timing-driven placement/route flow plus pre- and post-route physical
# optimization so small netlist changes do not leave the dense UDP/DDR path
# dependent on Vivado's default placement choice.
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraNetDelay_high ${impl_run}
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true ${impl_run}
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore ${impl_run}
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore ${impl_run}
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true ${impl_run}
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore ${impl_run}

reset_run ${impl_run}
launch_runs ${impl_run} -jobs 8
wait_on_run ${impl_run}

# Check implementation status
set impl_status [get_property STATUS ${impl_run}]
set impl_progress [get_property PROGRESS ${impl_run}]

puts "INFO: Implementation status: ${impl_status}"
puts "INFO: Implementation progress: ${impl_progress}"

if {${impl_progress} != "100%" || ![string match "*Complete!" ${impl_status}]} {
    puts "ERROR: Implementation failed!"
    exit 1
}

# Open implemented design for reporting
open_run impl_1

# Save a stable checkpoint for the next implementation iteration only after
# the current run has completed successfully.
write_checkpoint -force ${impl_incremental_checkpoint}
puts "INFO: Saved implementation incremental checkpoint: ${impl_incremental_checkpoint}"

# Generate reports
set report_dir "${vivado_dir}/work/${proj_name}.runs/impl_1/reports"
file mkdir ${report_dir}

puts "INFO: Generating implementation reports..."
report_utilization -file ${report_dir}/post_impl_util.rpt
report_timing_summary -file ${report_dir}/post_impl_timing.rpt
report_power -file ${report_dir}/post_impl_power.rpt
report_drc -file ${report_dir}/post_impl_drc.rpt

set failing_setup_paths [get_timing_paths -quiet -delay_type max -slack_lesser_than 0 -max_paths 1]
set failing_hold_paths [get_timing_paths -quiet -delay_type min -slack_lesser_than 0 -max_paths 1]
if {[llength ${failing_setup_paths}] > 0 || [llength ${failing_hold_paths}] > 0} {
    puts "ERROR: Implementation completed with timing violations"
    exit 1
}

puts "INFO: Implementation complete"
close_project
