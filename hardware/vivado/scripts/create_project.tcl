# Vivado Project Creation Script

set script_path [file dirname [file normalize [info script]]]
set vivado_dir [file dirname $script_path]
set proj_name "zcu216_rfdc"
set proj_dir "${vivado_dir}/work"

puts "INFO: Creating Vivado project..."
puts "INFO: Project name: ${proj_name}"
puts "INFO: Project directory: ${proj_dir}"

# Create project
create_project -force ${proj_name} ${proj_dir} -part xczu49dr-ffvf1760-2-e

# Set project properties
set_property board_part xilinx.com:zcu216:part0:2.0 [current_project]
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

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
    if {[llength $rtl_files] > 0} {
        add_files -norecurse $rtl_files
        puts "INFO: Added [llength $rtl_files] RTL source files"
    }
}

# Add constraint files
set xdc_dir "${vivado_dir}/xdc"
if {[file exists ${xdc_dir}]} {
    puts "INFO: Adding constraint files from ${xdc_dir}"
    set xdc_files [glob -nocomplain ${xdc_dir}/*.xdc]
    if {[llength $xdc_files] > 0} {
        add_files -fileset constrs_1 -norecurse $xdc_files
        puts "INFO: Added [llength $xdc_files] constraint files"
    }
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

# Create AXIS Async FIFO IP
set async_fifo_script "${script_path}/axis_async_fifo_128.tcl"
if {[file exists ${async_fifo_script}]} {
    source ${async_fifo_script}
    puts "INFO: AXIS Async FIFO IP created"
} else {
    puts "WARN: AXIS Async FIFO script not found: ${async_fifo_script}"
}

# Create and configure Block Design
puts "INFO: Creating Block Design..."
set bd_script "${vivado_dir}/bd/design_1.tcl"
if {[file exists ${bd_script}]} {
    source ${bd_script}
    puts "INFO: Block Design created from ${bd_script}"

    # Generate Block Design
    generate_target all [get_files *.bd]

    # Create HDL wrapper
    set bd_files [get_files *.bd]
    if {[llength $bd_files] > 0} {
        make_wrapper -files [get_files *.bd] -top
        set wrapper_file [get_files *_wrapper.v]
        add_files -norecurse $wrapper_file
        set_property top [file rootname [file tail $wrapper_file]] [current_fileset]
        puts "INFO: HDL wrapper created and set as top"
    }
} else {
    puts "WARN: Block Design script not found: ${bd_script}"
}

# Update compile order
update_compile_order -fileset sources_1

puts "INFO: Project creation complete"
puts "INFO: Project file: ${proj_dir}/${proj_name}.xpr"
