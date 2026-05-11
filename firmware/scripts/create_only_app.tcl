#!/usr/bin/env xsct
# Create Vitis Application
# Usage: xsct create_only_app.tcl <app_name> <src_dir>

if {$argc != 2} {
    puts "Usage: xsct create_only_app.tcl <app_name> <src_dir>"
    exit 1
}

set app_name [lindex $argv 0]
set src_dir [lindex $argv 1]

set script_dir [file dirname [file normalize [info script]]]
set workspace_dir "${script_dir}/../workspace"

puts "=========================================="
puts "Creating Vitis Application"
puts "=========================================="
puts "App Name: ${app_name}"
puts "Source Dir: ${src_dir}"
puts "Workspace: ${workspace_dir}"
puts ""

# Set workspace
setws ${workspace_dir}

# Get platform path
set platform_path "${workspace_dir}/hw_platform/export/hw_platform"

# Add platform to repository
puts "Adding platform to repository..."
repo -add-platforms ${platform_path}

# Create application
puts "Creating application..."
puts "Platform path: ${platform_path}"
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
