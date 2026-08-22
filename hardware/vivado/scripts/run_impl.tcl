# Vivado Implementation Script

set script_path [file dirname [file normalize [info script]]]
set vivado_dir [file dirname $script_path]
source "${script_path}/target_config.tcl"
source "${script_path}/reference_xxv_dcp.tcl"
source "${script_path}/build_options.tcl"

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
set proj_dir [expr {[info exists ::env(VIVADO_WORK_DIR)] ? $::env(VIVADO_WORK_DIR) : "${vivado_dir}/work"}]
set proj_file "${proj_dir}/${proj_name}.xpr"

puts "INFO: Opening project ${proj_file}"
open_project ${proj_file}

# Reuse the last successful routed design as the implementation reference.
# Keep this checkpoint outside impl_1 because reset_run removes the run
# directory contents before the next launch.
set incremental_dir "${proj_dir}/incremental"
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
            if {[ooc_run_complete ${rfdc_run}]} {
                puts "INFO: RFDC OOC ${rfdc_run} already complete; skipping duplicate synthesis"
                continue
            }
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
            if {[ooc_run_complete ${ddr_run}]} {
                puts "INFO: DDR4 OOC ${ddr_run} already complete; skipping duplicate synthesis"
                continue
            }
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

set impl_mode [build_option_get IMPL_MODE auto]
set impl_profiles [list]
switch -- ${impl_mode} {
    auto {
        set impl_profiles [list balanced aggressive]
    }
    fast {
        set impl_profiles [list fast]
    }
    balanced {
        set impl_profiles [list balanced aggressive]
    }
    aggressive {
        set impl_profiles [list aggressive]
    }
    default {
        puts "WARNING: Unknown IMPL_MODE=${impl_mode}; defaulting to auto"
        set impl_profiles [list balanced aggressive]
    }
}
puts "INFO: Implementation profiles: [join ${impl_profiles} { -> }]"

proc impl_apply_profile {impl_run profile} {
    set place_directive Default
    set route_directive Default
    set phys_directive Default
    set phys_opt_enabled false
    set post_route_phys_opt_enabled false

    switch -- ${profile} {
        fast {
            set place_directive Quick
            set route_directive Quick
        }
        balanced {
            set phys_opt_enabled true
            set post_route_phys_opt_enabled true
        }
        aggressive {
            set place_directive ExtraNetDelay_high
            set route_directive AggressiveExplore
            set phys_directive AggressiveExplore
            set phys_opt_enabled true
            set post_route_phys_opt_enabled true
        }
        default {
            puts "WARNING: Unknown profile=${profile}; using fast directives"
            set place_directive Quick
            set route_directive Quick
        }
    }

    set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ${place_directive} ${impl_run}
    set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED ${phys_opt_enabled} ${impl_run}
    set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE ${phys_directive} ${impl_run}
    set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE ${route_directive} ${impl_run}
    set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED ${post_route_phys_opt_enabled} ${impl_run}
    set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE ${phys_directive} ${impl_run}
}

proc impl_profile_timing_clean {} {
    set failing_setup_paths [get_timing_paths -quiet -delay_type max -slack_lesser_than 0 -max_paths 1]
    set failing_hold_paths [get_timing_paths -quiet -delay_type min -slack_lesser_than 0 -max_paths 1]
    if {[llength ${failing_setup_paths}] > 0 || [llength ${failing_hold_paths}] > 0} {
        puts "WARNING: Timing violations remain after this implementation profile"
        return 0
    }
    return 1
}

proc impl_run_profile {impl_run profile} {
    puts "INFO: Running implementation with profile=${profile}"
    impl_apply_profile ${impl_run} ${profile}
    reset_run ${impl_run}
    launch_runs ${impl_run} -jobs 8
    wait_on_run ${impl_run}

    set impl_status [get_property STATUS ${impl_run}]
    set impl_progress [get_property PROGRESS ${impl_run}]
    puts "INFO: Implementation status: ${impl_status}"
    puts "INFO: Implementation progress: ${impl_progress}"
    # Vivado reports a routed-but-timing-failing run as
    # "route_design Complete, Failed Timing!".  That is a valid completed
    # profile and must be passed to the timing check so auto mode can retry
    # with the next implementation strategy.
    if {${impl_progress} != "100%" || ![string match "*Complete*" ${impl_status}]} {
        puts "ERROR: Implementation failed with profile=${profile}"
        exit 1
    }

    open_run impl_1
    return [impl_profile_timing_clean]
}

set impl_ok 0
foreach profile ${impl_profiles} {
    set impl_ok [impl_run_profile ${impl_run} ${profile}]
    if {$impl_ok} {
        break
    }
    close_design
}
if {!$impl_ok} {
    puts "ERROR: Implementation completed but timing violations remain after all profiles"
    exit 1
}

# Save a stable checkpoint for the next implementation iteration only after
# the current run has completed successfully.
write_checkpoint -force ${impl_incremental_checkpoint}
puts "INFO: Saved implementation incremental checkpoint: ${impl_incremental_checkpoint}"

# Generate reports
set report_dir "${proj_dir}/${proj_name}.runs/impl_1/reports"
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
