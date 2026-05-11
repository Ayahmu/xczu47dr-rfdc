#!/usr/bin/env vivado -mode batch -source
# ZCU216 RFDC Project Build Script
# This script creates the Vivado project from scratch

# Get script directory
set script_dir [file dirname [file normalize [info script]]]
set proj_name "zcu216_rfdc"
set work_dir "${script_dir}/work"

# Create project
puts "Creating Vivado project: ${proj_name}"
create_project -force ${proj_name} ${work_dir} -part xczu49dr-ffvf1760-2-e

# Set board part
set_property board_part xilinx.com:zcu216:part0:2.0 [current_project]

# Add Verilog source files
puts "Adding source files..."
if {[glob -nocomplain ${script_dir}/src/*.v] != ""} {
    add_files [glob ${script_dir}/src/*.v]
}
if {[glob -nocomplain ${script_dir}/src/*.sv] != ""} {
    add_files [glob ${script_dir}/src/*.sv]
}

# Add constraint files
puts "Adding constraint files..."
if {[glob -nocomplain ${script_dir}/xdc/*.xdc] != ""} {
    add_files -fileset constrs_1 [glob ${script_dir}/xdc/*.xdc]
}

# Create Block Design
puts "Creating Block Design..."
source ${script_dir}/bd/design_1.tcl

# Source IP configuration scripts
puts "Configuring IP cores..."
if {[file exists ${script_dir}/scripts/axis_data_fifo_1.tcl]} {
    source ${script_dir}/scripts/axis_data_fifo_1.tcl
}
if {[file exists ${script_dir}/scripts/axi_datamover_0.tcl]} {
    source ${script_dir}/scripts/axi_datamover_0.tcl
}
if {[file exists ${script_dir}/scripts/axis_async_fifo_128.tcl]} {
    source ${script_dir}/scripts/axis_async_fifo_128.tcl
}

# Generate wrapper
puts "Generating HDL wrapper..."
make_wrapper -files [get_files ${work_dir}/${proj_name}.srcs/sources_1/bd/design_1/design_1.bd] -top
add_files -norecurse ${work_dir}/${proj_name}.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "=========================================="
puts "Project created successfully!"
puts "Location: ${work_dir}"
puts "=========================================="
puts ""
puts "Next steps:"
puts "  1. Open project: vivado ${work_dir}/${proj_name}.xpr"
puts "  2. Run synthesis: make synth"
puts "  3. Run implementation: make impl"
puts "  4. Generate bitstream: make bitstream"
puts "  5. Export XSA: make xsa"
