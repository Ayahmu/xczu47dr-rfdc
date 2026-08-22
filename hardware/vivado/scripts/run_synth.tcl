# Vivado Synthesis Script

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
set proj_dir [expr {[info exists ::env(VIVADO_WORK_DIR)] ? $::env(VIVADO_WORK_DIR) : "${vivado_dir}/work"}]
set proj_file "${proj_dir}/${proj_name}.xpr"

puts "INFO: Opening project ${proj_file}"
open_project ${proj_file}

# Reuse the last successful synthesis checkpoint when available.  The
# checkpoint is kept outside the run directory because reset_run removes the
# generated files belonging to synth_1.
set incremental_dir "${proj_dir}/incremental"
file mkdir ${incremental_dir}
set synth_incremental_checkpoint "${incremental_dir}/${proj_name}_synth.dcp"
set synth_run [get_runs -quiet synth_1]
if {[llength ${synth_run}] > 0 && [file exists ${synth_incremental_checkpoint}]} {
    set_property STEPS.SYNTH_DESIGN.ARGS.INCREMENTAL_MODE quick ${synth_run}
    #set_property STEPS.SYNTH_DESIGN.ARGS.INCREMENTAL_CHECKPOINT ${synth_incremental_checkpoint} ${synth_run}
    
    puts "INFO: Incremental synthesis enabled with ${synth_incremental_checkpoint}"
} else {
    puts "INFO: No synthesis checkpoint found; running a full synthesis"
}

puts "INFO: Skipping XXV Ethernet OOC synthesis; using reference DCP"

#restore_reference_xxv_dcp ${vivado_dir} ${target}

set bd_file [get_files -quiet ${proj_dir}/${proj_name}.srcs/sources_1/bd/design_1/design_1.bd]
if {[llength ${bd_file}] > 0} {
    puts "INFO: Regenerating Block Design targets before synthesis"
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

puts "INFO: Starting synthesis..."
reset_run synth_1
# Never let an automatically imported prior DCP hide RTL changes. This is
# especially important for the RFDC runtime FSM, which must match the UDP
# protocol and cannot safely reuse a stale incremental partition.
set_property incremental_checkpoint {} [get_runs synth_1]
launch_runs synth_1 -jobs 8
wait_on_run synth_1

# Check synthesis status
set synth_status [get_property STATUS [get_runs synth_1]]
set synth_progress [get_property PROGRESS [get_runs synth_1]]

puts "INFO: Synthesis status: ${synth_status}"
puts "INFO: Synthesis progress: ${synth_progress}"

if {${synth_status} != "synth_design Complete!"} {
    puts "ERROR: Synthesis failed!"
    exit 1
}

# Open synthesized design for reporting
open_run synth_1

# Save a stable checkpoint for the next synthesis iteration only after the
# current run has completed successfully.
write_checkpoint -force ${synth_incremental_checkpoint}
puts "INFO: Saved synthesis incremental checkpoint: ${synth_incremental_checkpoint}"

# Generate reports
set report_dir "${proj_dir}/${proj_name}.runs/synth_1/reports"
file mkdir ${report_dir}

puts "INFO: Generating synthesis reports..."
report_utilization -file ${report_dir}/post_synth_util.rpt
report_timing_summary -file ${report_dir}/post_synth_timing.rpt

puts "INFO: Synthesis complete"
close_project
