# Vivado Project Creation Script

set script_path [file dirname [file normalize [info script]]]
set vivado_dir [file dirname $script_path]
source "${script_path}/target_config.tcl"

set target "zcu216"
if {$argc > 0} {
    set target [lindex $argv 0]
}
if {![target_config_exists $target]} {
    target_config_error $target
}

set proj_name [target_config_get $target project_basename]
set proj_dir "${vivado_dir}/work"
set target_part [target_config_get $target part]
set target_board_part [target_config_get $target board_part]
set target_top_module [target_config_get $target top_module]

puts "INFO: Creating Vivado project..."
puts "INFO: Target: ${target}"
puts "INFO: Project name: ${proj_name}"
puts "INFO: Project directory: ${proj_dir}"
puts "INFO: Part: ${target_part}"
puts "INFO: Top module: ${target_top_module}"

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
if {$target eq "custom_xczu47dr"} {
    puts "INFO: Enabling CUSTOM_XCZU47DR Verilog define"
    set_property verilog_define {CUSTOM_XCZU47DR} [current_fileset]
}

# Add Chisel generated Verilog files
set chisel_dir "${vivado_dir}/../chisel/generated"
if {[file exists ${chisel_dir}]} {
    puts "INFO: Adding Chisel generated files from ${chisel_dir}"
    set verilog_files [glob -nocomplain ${chisel_dir}/*.v ${chisel_dir}/*.sv]
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
        if {$rtl_tail ne "design_1_wrapper.v"} {
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
if {[file exists ${udp_src_dir}]} {
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
set xxv_xci "${vivado_dir}/ip/xxv_ethernet_1/xxv_ethernet.xci"
if {[file exists ${xxv_xci}]} {
    puts "INFO: Adding reference XXV Ethernet IP: ${xxv_xci}"
    add_files -norecurse ${xxv_xci}
    set_property generate_synth_checkpoint true [get_files ${xxv_xci}]
} else {
    puts "WARN: Reference XXV Ethernet IP not found: ${xxv_xci}"
}

set fifo64_xci "${vivado_dir}/ip/fifo64_2/fifo64.xci"
if {[file exists ${fifo64_xci}]} {
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
    puts "INFO: Added [llength $resolved_xdc_files] constraint files for TARGET=${target}"
}

# Create standalone IP cores
puts "INFO: Creating standalone IP cores..."

# Create AXI DataMover IP
set datamover_script "${script_path}/axi_datamover_0.tcl"
if {[file exists ${datamover_script}]} {
    source ${datamover_script}
    puts "INFO: AXI DataMover IP created"
} else {
    puts "WARN: AXI DataMover script not found: ${datamover_script}"
}

# Create instruction FIFO IP used by waveform_system_top.v
set instr_fifo_script "${script_path}/axis_data_fifo_1.tcl"
if {[file exists ${instr_fifo_script}]} {
    source ${instr_fifo_script}
    puts "INFO: AXIS Data FIFO IP created"
} else {
    puts "WARN: AXIS Data FIFO script not found: ${instr_fifo_script}"
}

# Create AXIS Async FIFO IP
set async_fifo_script "${script_path}/axis_async_fifo_128.tcl"
if {[file exists ${async_fifo_script}]} {
    source ${async_fifo_script}
    puts "INFO: AXIS Async FIFO IP created"
} else {
    puts "WARN: AXIS Async FIFO script not found: ${async_fifo_script}"
}

# Create ILA IPs used for custom 10G UDP to RFDC debug and acceptance.
set ila_udp_ddr_script "${script_path}/ila_udp_ddr.tcl"
if {[file exists ${ila_udp_ddr_script}]} {
    source ${ila_udp_ddr_script}
    puts "INFO: DDR-domain UDP/DataMover ILA IP created"
} else {
    puts "WARN: DDR-domain ILA script not found: ${ila_udp_ddr_script}"
}

set ila_dac_axis_script "${script_path}/ila_dac_axis.tcl"
if {[file exists ${ila_dac_axis_script}]} {
    source ${ila_dac_axis_script}
    puts "INFO: DAC-domain RFDC AXIS ILA IP created"
} else {
    puts "WARN: DAC-domain ILA script not found: ${ila_dac_axis_script}"
}

# Create and configure Block Design
puts "INFO: Creating Block Design..."
set bd_script "${vivado_dir}/bd/design_1.tcl"
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
    set wrapper_file [get_files -quiet *_wrapper.v]
    if {[llength $wrapper_file] > 0} {
        add_files -norecurse $wrapper_file
        set_property top [file rootname [file tail [lindex $wrapper_file 0]]] [current_fileset]
        puts "INFO: HDL wrapper created and set as top"
    } else {
        puts "ERROR: HDL wrapper file not found"
        exit 1
    }
} else {
    puts "WARN: Block Design script not found: ${bd_script}"
}

# Update compile order
update_compile_order -fileset sources_1
set_property top ${target_top_module} [current_fileset]
update_compile_order -fileset sources_1

puts "INFO: Project creation complete"
puts "INFO: Project file: ${proj_dir}/${proj_name}.xpr"
