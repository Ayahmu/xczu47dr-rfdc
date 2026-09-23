# Vivado Project Creation Script

set script_path [file dirname [file normalize [info script]]]
set vivado_dir [file dirname $script_path]
source "${script_path}/target_config.tcl"
source "${script_path}/reference_xxv_dcp.tcl"
source "${script_path}/build_options.tcl"
source "${script_path}/build_identity.tcl"

set target "custom_xczu47dr_waveform"
if {$argc > 0} {
    set target [lindex $argv 0]
}
if {![target_config_exists $target]} {
    target_config_error $target
}

set proj_name [target_config_get $target project_basename]
set proj_dir [expr {[info exists ::env(VIVADO_WORK_DIR)] ? $::env(VIVADO_WORK_DIR) : "${vivado_dir}/work"}]
file mkdir ${proj_dir}
set generated_ip_dir "${proj_dir}/ip"
file mkdir ${generated_ip_dir}
set target_part [target_config_get $target part]
set target_board_part [target_config_get $target board_part]
set target_top_module [target_config_get $target top_module]
set target_generics [target_config_get $target generics]
set is_bandwidth_target [expr {$target eq "custom_xczu47dr_bw"}]
set is_waveform_target [expr {$target eq "custom_xczu47dr_waveform"}]
set enable_ila [expr {[build_option_get ENABLE_ILA 0] ne "0"}]

# Stamp the exact source revision and protocol identity into every generated
# RTL compile.  The Top module consumes these preprocessor defines, so a
# STATUS/HELLO response can be tied back to this project without relying on a
# hand-maintained constant in Verilog.
set source_commit [rf2_identity_source_commit ${script_path}]
set build_profile_id [rf2_identity_profile_id ${target}]
set trigger_path_version 3

puts "INFO: Creating Vivado project..."
puts "INFO: Target: ${target}"
puts "INFO: Project name: ${proj_name}"
puts "INFO: Project directory: ${proj_dir}"
puts "INFO: Part: ${target_part}"
puts "INFO: Top module: ${target_top_module}"

# Avoid stale file references when the IP/RTL set changes between runs.
foreach stale_path [list \
    "${proj_dir}/${proj_name}.xpr" \
    "${proj_dir}/${proj_name}.srcs" \
    "${proj_dir}/${proj_name}.gen" \
    "${proj_dir}/${proj_name}.runs" \
    "${proj_dir}/${proj_name}.cache" \
    "${proj_dir}/${proj_name}.hw" \
    "${proj_dir}/${proj_name}.ip_user_files" \
    "${proj_dir}/${proj_name}.sim" \
] {
    if {[file exists ${stale_path}]} {
        puts "INFO: Removing stale project artifact: ${stale_path}"
        file delete -force ${stale_path}
    }
}

# Create project
create_project -force ${proj_name} ${proj_dir} -part ${target_part}

# Set project properties
if {$target_board_part ne ""} {
    puts "INFO: Board part: ${target_board_part}"
    set_property board_part ${target_board_part} [current_project]
} else {
    puts "INFO: No board_part for TARGET=${target}"
}
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
puts "INFO: Enabling target Verilog define"
if {$is_bandwidth_target} {
    set define_list {CUSTOM_XCZU47DR_BW}
} elseif {$is_waveform_target} {
    set define_list {CUSTOM_XCZU47DR}
} else {
}
if {!$is_bandwidth_target && !$is_waveform_target} {
    # Kept only so this shared script fails loudly if a non-production target
    # is reintroduced without explicitly defining its compile contract.
    error "non-production target compile defines are not supported"
}
if {$enable_ila} { lappend define_list ENABLE_ILA }
lappend define_list RF2_BUILD_PROFILE_ID=32'd${build_profile_id}
lappend define_list RF2_TRIGGER_PATH_VERSION=32'd${trigger_path_version}
lappend define_list RF2_SOURCE_COMMIT_ID=32'h${source_commit}
set_property verilog_define ${define_list} [current_fileset]

set build_manifest_file "${proj_dir}/build_manifest.json"
rf2_identity_write_manifest ${build_manifest_file} ${target} ${source_commit} ${build_profile_id} ${trigger_path_version} ${enable_ila}

set rfdc_generated_config "${vivado_dir}/../chisel/generated/rfdc_custom_xczu47dr_config.tcl"
set ddr_generated_config "${vivado_dir}/../chisel/generated/ddr_custom_xczu47dr_config.tcl"
if {!$is_bandwidth_target && ![file exists ${rfdc_generated_config}]} {
    puts "ERROR: Missing generated RFDC configuration: ${rfdc_generated_config}"
    puts "ERROR: Run hardware/chisel/build.sh rfdc or make chisel first."
    exit 1
}
if {![file exists ${ddr_generated_config}]} {
    puts "ERROR: Missing generated DDR4 configuration: ${ddr_generated_config}"
    puts "ERROR: Run hardware/chisel/build.sh ddr or make chisel first."
    exit 1
}
if {!$is_bandwidth_target} {
    source ${rfdc_generated_config}
}
source ${ddr_generated_config}

if {!$is_bandwidth_target} {
    puts "INFO: Creating project-level RFDC IP outside block design"
    set rfdc_ip_dir "${generated_ip_dir}"
    file mkdir ${rfdc_ip_dir}
    create_ip -force -name usp_rf_data_converter -vendor xilinx.com -library ip -version 2.6 \
        -module_name rfdc_custom_xczu47dr_ip -dir ${rfdc_ip_dir}
    set rfdc_ip [get_ips rfdc_custom_xczu47dr_ip]
    set_property -dict [::rfdc_custom_xczu47dr::config] ${rfdc_ip}
    set rfdc_ip_file [get_files -quiet "${rfdc_ip_dir}/rfdc_custom_xczu47dr_ip/rfdc_custom_xczu47dr_ip.xci"]
    if {[llength ${rfdc_ip_file}] == 0} {
        puts "ERROR: RFDC IP XCI not found after create_ip"
        exit 1
    }
    set_property generate_synth_checkpoint true ${rfdc_ip_file}
    # DAC2_Refclk_Freq is generated by Chisel (128.000 MHz).  Do not
    # override it here: the HMC7044 DAC reference outputs are 128 MHz.
    set_property -dict [list \
  CONFIG.DAC0_Multi_Tile_Sync {true} \
  CONFIG.DAC1_Multi_Tile_Sync {true} \
  CONFIG.DAC2_Multi_Tile_Sync {true} \
  CONFIG.DAC3_Multi_Tile_Sync {true} \
] [get_ips rfdc_custom_xczu47dr_ip]
    generate_target all ${rfdc_ip_file}

}


    
puts "INFO: Creating project-level DDR4 IP outside block design"
set ddr_ip_dir "${generated_ip_dir}"
file mkdir ${ddr_ip_dir}
create_ip -force -name ddr4 -vendor xilinx.com -library ip -version 2.2 \
    -module_name ddr_custom_xczu47dr_ip -dir ${ddr_ip_dir}
set ddr_ip [get_ips ddr_custom_xczu47dr_ip]
set_property -dict [::ddr_custom_xczu47dr::config] ${ddr_ip}
set ddr_ip_file [get_files -quiet "${ddr_ip_dir}/ddr_custom_xczu47dr_ip/ddr_custom_xczu47dr_ip.xci"]
if {[llength ${ddr_ip_file}] == 0} {
    puts "ERROR: DDR4 IP XCI not found after create_ip"
    exit 1
}
set_property generate_synth_checkpoint true ${ddr_ip_file}
generate_target all ${ddr_ip_file}

# Add Chisel generated Verilog files
set chisel_dir "${vivado_dir}/../chisel/generated"
if {[file exists ${chisel_dir}]} {
    puts "INFO: Adding Chisel generated files from ${chisel_dir}"
    if {$is_bandwidth_target} {
        set verilog_files [glob -nocomplain ${chisel_dir}/Ddr4CustomXczu47dr.v ${chisel_dir}/ChiselProcSysReset.v]
    } else {
        set verilog_files [glob -nocomplain ${chisel_dir}/*.v ${chisel_dir}/*.sv]
    }
    if {[llength $verilog_files] > 0} {
        add_files -norecurse $verilog_files
        puts "INFO: Added [llength $verilog_files] Chisel Verilog files"
    } else {
        puts "WARN: No Verilog files found in ${chisel_dir}"
    }
} else {
    puts "WARN: Chisel generated directory not found: ${chisel_dir}"
}

# Add RTL source files
set src_dir "${vivado_dir}/src"
if {[file exists ${src_dir}]} {
    puts "INFO: Adding RTL source files from ${src_dir}"
    set rtl_files [glob -nocomplain ${src_dir}/*.v ${src_dir}/*.sv ${src_dir}/*.vhd]
    set filtered_rtl_files [list]
    foreach rtl_file $rtl_files {
        set rtl_tail [file tail $rtl_file]
        set is_bw_file [expr {$rtl_tail in {
            "TopBandwidthCore.v"
            "TopBandwidthXczu47dr.v"
            "waveform_bandwidth_top.v"
            "bandwidth_sink.v"
            "bandwidth_axi_regs.v"
        }}]
        set is_rfdc_file [expr {$rtl_tail in {
            "Top.v"
            "TopCustomXczu47dr.v"
            "waveform_playback_controller.v"
            "waveform_trigger_cdc.v"
            "waveform_status_cdc.v"
            "waveform_upload_writer.v"
            "waveform_fifo_mask_adapter.v"
            "hmc7044.vhd"
            "axis_async_fifo_256_stub.v"
            "rfdc_custom_xczu47dr_ip_stub.v"
        }}]
        if {$rtl_tail eq "design_1_wrapper.v" || $rtl_tail eq "axis_128_to_256.v"} {
            continue
        }
        # The waveform product has one descriptor/DDR writer.  These retired
        # instruction/data-writer sources must not enter the Vivado source set
        # even though they remain in the checkout for diagnostics and history.
        if {$is_waveform_target && $rtl_tail in {
            "udp_waveform_ddr_writer.v"
            "udp64_to_axis128_instr.v"
            "sync_trigger_link.v"
            "dac_trigger_emitter.v"
            "dac_ext_trigger_capture.v"
            "dac_trigger_latency_probe.v"
        }} {
            puts "INFO: Excluding retired waveform RTL: ${rtl_tail}"
            continue
        }
        if {$is_bandwidth_target && $is_rfdc_file} {
            continue
        }
        if {!$is_bandwidth_target && $is_bw_file} {
            continue
        }
        if {$is_bandwidth_target && $rtl_tail eq "udp"} {
            continue
        }
        if {1} {
            lappend filtered_rtl_files $rtl_file
        }
    }
    if {[llength $filtered_rtl_files] > 0} {
        add_files -norecurse $filtered_rtl_files
        puts "INFO: Added [llength $filtered_rtl_files] RTL source files"
    }
}

# Add reference 10G UDP/XXV Ethernet RTL for the custom XCZU47DR data path.
set udp_src_dir "${src_dir}/udp"
if {!$is_bandwidth_target && [file exists ${udp_src_dir}]} {
    puts "INFO: Adding 10G UDP RTL source files from ${udp_src_dir}"
    set udp_rtl_files [glob -nocomplain ${udp_src_dir}/*.v ${udp_src_dir}/*.sv ${udp_src_dir}/*.vhd]
    if {[llength $udp_rtl_files] > 0} {
        add_files -norecurse $udp_rtl_files
        puts "INFO: Added [llength $udp_rtl_files] 10G UDP RTL source files"
    } else {
        puts "WARN: No 10G UDP RTL files found in ${udp_src_dir}"
    }
}

# Import the reference XXV Ethernet IP used by udp_10G.
set xxv_src_dir "${vivado_dir}/ip/xxv_ethernet_1"
set xxv_local_dir "${generated_ip_dir}/xxv_ethernet_1"
if {[file exists ${xxv_src_dir}] && ![file exists ${xxv_local_dir}]} {
    file copy -force ${xxv_src_dir} ${xxv_local_dir}
}
set xxv_xci "${xxv_local_dir}/xxv_ethernet.xci"
if {!$is_bandwidth_target && [file exists ${xxv_xci}]} {
    puts "INFO: Adding reference XXV Ethernet IP: ${xxv_xci}"
    # Keep the XCI in the normal project source set. Vivado can then carry
    # the managed IP identity, constraints, and OOC checkpoint into the
    # parent synthesis/implementation flow. A hand-injected
    # read_checkpoint -cell is deliberately not used: it loses the XCI
    # provenance and creates Vivado 12-5469/Project 1-840 critical warnings.
    read_ip ${xxv_xci}
    set xxv_ip [get_ips -quiet xxv_ethernet]
    if {[llength ${xxv_ip}] != 1} {
        puts "ERROR: Managed XXV Ethernet IP was not imported"
        exit 1
    }
    generate_target all ${xxv_ip}
    set xxv_xci_file [get_files -quiet -all ${xxv_xci}]
    if {[llength ${xxv_xci_file}] == 1} {
        set_property USED_IN_SYNTHESIS true ${xxv_xci_file}
        set_property USED_IN_IMPLEMENTATION true ${xxv_xci_file}
        set_property generate_synth_checkpoint true ${xxv_xci_file}
    }
    puts "INFO: XXV Ethernet XCI is managed by the parent project"
} else {
    puts "WARN: Reference XXV Ethernet IP not found: ${xxv_xci}"
}

set fifo64_src_dir "${vivado_dir}/ip/fifo64_2"
set fifo64_local_dir "${generated_ip_dir}/fifo64_2"
if {[file exists ${fifo64_src_dir}] && ![file exists ${fifo64_local_dir}]} {
    file copy -force ${fifo64_src_dir} ${fifo64_local_dir}
}
set fifo64_xci "${fifo64_local_dir}/fifo64.xci"
if {!$is_bandwidth_target && [file exists ${fifo64_xci}]} {
    puts "INFO: Adding reference fifo64 IP: ${fifo64_xci}"
    add_files -norecurse ${fifo64_xci}
    set_property generate_synth_checkpoint false [get_files ${fifo64_xci}]
} else {
    puts "WARN: Reference fifo64 IP not found: ${fifo64_xci}"
}

# Add constraint files
set target_xdc_files [target_config_get $target xdc_files]
set resolved_xdc_files [list]
foreach xdc_file $target_xdc_files {
    set resolved_xdc_file [file normalize "${vivado_dir}/${xdc_file}"]
    if {![file exists $resolved_xdc_file]} {
        puts "ERROR: Constraint file not found for TARGET=${target}: ${resolved_xdc_file}"
        exit 1
    }
    lappend resolved_xdc_files $resolved_xdc_file
}
if {[llength $resolved_xdc_files] > 0} {
    puts "INFO: Adding target constraint files: [join $target_xdc_files {, }]"
    add_files -fileset constrs_1 -norecurse $resolved_xdc_files
    foreach tdc_xdc [get_files -quiet */tdc_placement.xdc] {
        set_property USED_IN_SYNTHESIS false $tdc_xdc
    }
    foreach tdc_xdc [get_files -quiet */tdc_timing.xdc] {
        set_property USED_IN_SYNTHESIS false $tdc_xdc
    }
    puts "INFO: Added [llength $resolved_xdc_files] constraint files for TARGET=${target}"
}

# Create standalone IP cores
puts "INFO: Creating standalone IP cores..."

# Create AXIS Async FIFO IP
set async_fifo_script "${script_path}/axis_async_fifo_256.tcl"
if {!$is_bandwidth_target && [file exists ${async_fifo_script}]} {
    source ${async_fifo_script}
    generate_target all [get_ips axis_async_fifo_256]
    puts "INFO: AXIS Async FIFO IP created"
} else {
    puts "WARN: AXIS Async FIFO script not found: ${async_fifo_script}"
}

# Create ILA IPs used for custom 10G UDP to RFDC debug and acceptance.
set ila_udp_ddr_script "${script_path}/ila_udp_ddr.tcl"
if {$enable_ila && !$is_bandwidth_target && [file exists ${ila_udp_ddr_script}]} {
    source ${ila_udp_ddr_script}
    puts "INFO: DDR-domain UDP/DataMover ILA IP created"
} else {
    puts "WARN: DDR-domain ILA script not found: ${ila_udp_ddr_script}"
}

set ila_dac_axis_script "${script_path}/ila_dac_axis.tcl"
if {$enable_ila && !$is_bandwidth_target && [file exists ${ila_dac_axis_script}]} {
  source ${ila_dac_axis_script}
  puts "INFO: DAC-domain RFDC AXIS ILA IP created"
} else {
    puts "WARN: DAC-domain ILA script not found: ${ila_dac_axis_script}"
}

set ila_hmc_event_script "${script_path}/ila_hmc_event.tcl"
if {$enable_ila && !$is_bandwidth_target && [file exists ${ila_hmc_event_script}]} {
    source ${ila_hmc_event_script}
    puts "INFO: HMC PL_CLK event ILA IP created"
} else {
    puts "WARN: HMC PL_CLK event ILA script not found: ${ila_hmc_event_script}"
}

set ila_s_axi_01_script "${script_path}/ila_s_axi_01.tcl"
if {$enable_ila && !$is_bandwidth_target && [file exists ${ila_s_axi_01_script}]} {
    source ${ila_s_axi_01_script}
    puts "INFO: S_AXI_01 ILA IP created"
} else {
    puts "WARN: S_AXI_01 ILA script not found: ${ila_s_axi_01_script}"
}

# Create 200 MHz clock generator for external trigger phase detection
set clk_200mhz_script "${script_path}/clk_gen_200mhz.tcl"
if {!$is_bandwidth_target && [file exists ${clk_200mhz_script}]} {
    source ${clk_200mhz_script}
    puts "INFO: 200 MHz clock generator IP created"
} else {
    puts "WARN: 200 MHz clock generator script not found: ${clk_200mhz_script}"
}

# Create and configure Block Design
puts "INFO: Creating Block Design..."
set bd_script "${vivado_dir}/bd/design_1.tcl"
if {$is_bandwidth_target} {
    set bd_script "${vivado_dir}/bd/design_1_bandwidth.tcl"
}
if {[file exists ${bd_script}]} {
    source ${bd_script}
    puts "INFO: Block Design created from ${bd_script}"

    set bd_file [get_files -quiet ${proj_dir}/${proj_name}.srcs/sources_1/bd/design_1/design_1.bd]
    if {$bd_file eq ""} {
        puts "ERROR: Top-level Block Design file not found"
        exit 1
    }

    # Generate Block Design
    generate_target all $bd_file

    puts "INFO: Validating Block Design..."
    validate_bd_design

    puts "INFO: Reporting IP status..."
    report_ip_status

    # Create HDL wrapper
    make_wrapper -files $bd_file -top
    set wrapper_file [file normalize "${proj_dir}/${proj_name}.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v"]
    if {[file exists $wrapper_file]} {
        add_files -norecurse $wrapper_file
        set_property top [file rootname [file tail $wrapper_file]] [current_fileset]
        puts "INFO: HDL wrapper created and set as top"
    } else {
        puts "ERROR: HDL wrapper file not found"
        exit 1
    }
} else {
    puts "WARN: Block Design script not found: ${bd_script}"
}

puts "INFO: Creating external DDR AXI SmartConnect Block Design..."
set ddr_axi_bd_script "${vivado_dir}/bd/ddr_axi_smartconnect.tcl"
if {$is_bandwidth_target} {
    set ddr_axi_bd_script "${vivado_dir}/bd/ddr_axi_smartconnect_bandwidth.tcl"
}
if {[file exists ${ddr_axi_bd_script}]} {
    source ${ddr_axi_bd_script}

    set ddr_axi_bd_file [get_files -quiet ${proj_dir}/${proj_name}.srcs/sources_1/bd/ddr_axi_smartconnect/ddr_axi_smartconnect.bd]
    if {$ddr_axi_bd_file eq ""} {
        puts "ERROR: DDR AXI SmartConnect Block Design file not found"
        exit 1
    }

    generate_target all $ddr_axi_bd_file
    make_wrapper -files $ddr_axi_bd_file -top
    set ddr_axi_wrapper_file [file normalize "${proj_dir}/${proj_name}.gen/sources_1/bd/ddr_axi_smartconnect/hdl/ddr_axi_smartconnect_wrapper.v"]
    if {[file exists $ddr_axi_wrapper_file]} {
        add_files -norecurse $ddr_axi_wrapper_file
        puts "INFO: External DDR AXI SmartConnect wrapper added"
    } else {
        puts "ERROR: DDR AXI SmartConnect wrapper file not found"
        exit 1
    }
} else {
    puts "ERROR: DDR AXI SmartConnect script not found: ${ddr_axi_bd_script}"
    exit 1
}

# Update compile order
update_compile_order -fileset sources_1
set_property top ${target_top_module} [current_fileset]
if {$target_generics ne ""} {
    puts "INFO: Top-level generics: ${target_generics}"
    set_property generic ${target_generics} [current_fileset]
}
update_compile_order -fileset sources_1

# The generated XXV OOC view in this Vivado installation is a
# Design_Linking-only encrypted cellview and cannot be used by write_bitstream.
# Keep the XCI as the managed project/IP contract, but restore the known
# bitstream-capable checkpoint into that managed OOC location before any parent
# synthesis or implementation run can consume it.  This is intentionally not a
# cell-level read_checkpoint injection.
prepare_reference_xxv_ooc_run ${vivado_dir} ${proj_dir} ${target} ${proj_name}

puts "INFO: Project creation complete"
puts "INFO: Project file: ${proj_dir}/${proj_name}.xpr"
