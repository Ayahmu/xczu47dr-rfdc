#!/usr/bin/env xsct
# Create Vitis Application from XSA
# Usage: xsct create_app.tcl <xsa_file> <app_name> <src_dir> <workspace_dir> <board_define>
# Set DRY_RUN=1 to print resolved paths without creating a Vitis workspace.

if {$argc != 5} {
    puts "Usage: xsct create_app.tcl <xsa_file> <app_name> <src_dir> <workspace_dir> <board_define>"
    puts "Example: xsct create_app.tcl ../hardware/vivado/output/zcu216_rfdc.xsa rfdc_app src ../workspace BOARD_ZCU216"
    exit 1
}

set xsa_file [lindex $argv 0]
set app_name [lindex $argv 1]
set src_dir [lindex $argv 2]
set workspace_dir [lindex $argv 3]
set board_define [lindex $argv 4]

puts "=========================================="
puts "Creating Vitis Application"
puts "=========================================="
puts "XSA File: ${xsa_file}"
puts "App Name: ${app_name}"
puts "Source Dir: ${src_dir}"
puts "Workspace: ${workspace_dir}"
puts "Board Define: -D${board_define}"
puts ""

if {[info exists ::env(DRY_RUN)] && $::env(DRY_RUN) eq "1"} {
    puts "DRY_RUN=1; skipping setws, platform create, source import, and build"
    puts "ELF: ${workspace_dir}/${app_name}/Debug/${app_name}.elf"
    exit 0
}

# Set workspace
setws ${workspace_dir}

# Create platform from XSA
puts "Creating platform from XSA..."
platform create -name hw_platform -hw ${xsa_file} -proc psu_cortexa53_0 -os standalone

# Add lwIP to the standalone BSP before the platform is generated.  Vitis
# 2024.2 XSCT accepts bsp setlib/config/write in the active domain context.
puts "Configuring standalone BSP with lwip220..."
domain active standalone_domain
bsp setlib -name lwip220
bsp config api_mode RAW_API
bsp config lwip_dhcp false
bsp config ipv6_enable false
bsp config pbuf_pool_size 2048
bsp write

# Generate platform
puts "Generating platform..."
platform generate -domains

# Create application
puts "Creating application..."
app create -name ${app_name} -platform hw_platform -domain standalone_domain -template "Empty Application(C)"

puts "Configuring compiler board define..."
app config -name ${app_name} define-compiler-symbols ${board_define}

# Import source files
puts "Importing source files..."
importsources -name ${app_name} -path ${src_dir}

# Vitis 2024.2 can generate managed-make rules that reference ../src even
# when importsources does not materialize the source tree. Copy explicitly so
# the generated Debug makefile has real prerequisites.
set app_src_dir [file join ${workspace_dir} ${app_name} src]
file delete -force ${app_src_dir}
file copy -force ${src_dir} ${app_src_dir}

# Build application
puts "Building application..."
app build -name ${app_name}

if {![file exists "${workspace_dir}/${app_name}/Debug/makefile"]} {
    puts "Regenerating application makefiles..."
    app build -name ${app_name}
}

puts ""
puts "=========================================="
puts "Application created successfully!"
puts "ELF: ${workspace_dir}/${app_name}/Debug/${app_name}.elf"
puts "=========================================="
