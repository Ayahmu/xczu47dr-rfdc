#!/usr/bin/env xsct
# Create Vitis Platform from XSA
# Usage: xsct create_platform.tcl <xsa_file>

if {$argc != 1} {
    puts "Usage: xsct create_platform.tcl <xsa_file>"
    exit 1
}

set xsa_file [lindex $argv 0]
set script_dir [file dirname [file normalize [info script]]]
set workspace_dir "${script_dir}/../workspace"

puts "=========================================="
puts "Creating Vitis Platform"
puts "=========================================="
puts "XSA File: ${xsa_file}"
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

puts ""
puts "=========================================="
puts "Platform created successfully!"
puts "Platform: ${workspace_dir}/hw_platform"
puts "=========================================="
