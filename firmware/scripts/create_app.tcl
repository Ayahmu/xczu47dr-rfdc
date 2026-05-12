#!/usr/bin/env xsct
# Create Vitis Application from XSA
# Usage: xsct create_app.tcl <xsa_file> <app_name> <src_dir>

if {$argc != 3} {
    puts "Usage: xsct create_app.tcl <xsa_file> <app_name> <src_dir>"
    puts "Example: xsct create_app.tcl ../hardware/vivado/output/zcu216_rfdc.xsa rfdc_app src"
    exit 1
}

set xsa_file [lindex $argv 0]
set app_name [lindex $argv 1]
set src_dir [lindex $argv 2]

set script_dir [file dirname [file normalize [info script]]]
set workspace_dir "${script_dir}/../workspace"

puts "=========================================="
puts "Creating Vitis Application"
puts "=========================================="
puts "XSA File: ${xsa_file}"
puts "App Name: ${app_name}"
puts "Source Dir: ${src_dir}"
puts "Workspace: ${workspace_dir}"
puts ""

# Set workspace
setws ${workspace_dir}

# Create platform from XSA
puts "Creating platform from XSA..."
platform create -name hw_platform -hw ${xsa_file} -proc psu_cortexa53_0 -os standalone

# Generate platform
puts "Generating platform..."
platform generate

# Create application
puts "Creating application..."
app create -name ${app_name} -platform hw_platform -domain standalone_domain -template "Empty Application(C)"

# Import source files
puts "Importing source files..."
importsources -name ${app_name} -path ${src_dir}

# Build application
puts "Building application..."
app build -name ${app_name}

puts ""
puts "=========================================="
puts "Application created successfully!"
puts "ELF: ${workspace_dir}/${app_name}/Debug/${app_name}.elf"
puts "=========================================="
