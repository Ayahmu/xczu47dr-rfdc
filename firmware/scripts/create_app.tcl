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

proc add_include_to_app_makefiles {debug_dir app_src_dir bsp_include_dir} {
    foreach entry [glob -nocomplain -directory ${debug_dir} *] {
        if {[file isdirectory ${entry}]} {
            add_include_to_app_makefiles ${entry} ${app_src_dir} ${bsp_include_dir}
        } elseif {[file tail ${entry}] eq "subdir.mk"} {
            set fp [open ${entry} r]
            set data [read ${fp}]
            close ${fp}
            if {[string first "-I${app_src_dir}" ${data}] < 0} {
                set data [string map [list "-I${bsp_include_dir}" "-I${app_src_dir} -I${bsp_include_dir}"] ${data}]
                set fp [open ${entry} w]
                puts -nonewline ${fp} ${data}
                close ${fp}
            }
        }
    }
}

# Set workspace
setws ${workspace_dir}

# Create platform from XSA
puts "Creating platform from XSA..."
platform create -name hw_platform -hw ${xsa_file} -proc psu_cortexa53_0 -os standalone

# Generate platform
puts "Generating platform..."
platform generate -domains

# Create application
puts "Creating application..."
app create -name ${app_name} -platform hw_platform -domain standalone_domain -template "Empty Application(C)"

puts "Configuring compiler board define..."
if {$board_define eq "BOARD_CUSTOM_XCZU47DR"} {
    set compiler_symbols "${board_define} -D__BAREMETAL__"
} else {
    set compiler_symbols ${board_define}
}
app config -name ${app_name} define-compiler-symbols ${compiler_symbols}

# Import source files
puts "Importing source files..."
importsources -name ${app_name} -path ${src_dir}

# Vitis 2024.2 can generate managed-make rules that reference ../src even
# when importsources does not materialize the source tree. Copy explicitly so
# the generated Debug makefile has real prerequisites.
set app_src_dir [file join ${workspace_dir} ${app_name} src]
file delete -force ${app_src_dir}
file copy -force ${src_dir} ${app_src_dir}

if {$board_define eq "BOARD_CUSTOM_XCZU47DR"} {
    puts "Injecting custom RFDC driver sources..."
    set rfdc_driver_src "/tools/Xilinx/Vitis/2024.2/data/embeddedsw/XilinxProcessorIPLib/drivers/rfdc_v12_3/src"
    if {![file isdirectory ${rfdc_driver_src}]} {
        puts "ERROR: RFDC driver source directory not found: ${rfdc_driver_src}"
        exit 1
    }

    foreach driver_file [glob -nocomplain -directory ${rfdc_driver_src} *] {
        if {[file isfile ${driver_file}]} {
            file copy -force ${driver_file} [file join ${app_src_dir} [file tail ${driver_file}]]
        }
    }

    set script_dir [file dirname [file normalize [info script]]]
    set custom_rfdc_g [file normalize [file join ${script_dir} .. src_custom custom_xczu47dr xrfdc_g.c]]
    set custom_metal_dir [file normalize [file join ${script_dir} .. src_custom custom_xczu47dr metal]]
    if {![file exists ${custom_rfdc_g}]} {
        puts "ERROR: Custom RFDC config table not found: ${custom_rfdc_g}"
        exit 1
    }
    if {![file isdirectory ${custom_metal_dir}]} {
        puts "ERROR: Custom libmetal shim not found: ${custom_metal_dir}"
        exit 1
    }
    file copy -force ${custom_rfdc_g} [file join ${app_src_dir} xrfdc_g.c]
    file copy -force ${custom_metal_dir} ${app_src_dir}
    set platform_bsp_include_dir [file join ${workspace_dir} hw_platform psu_cortexa53_0 standalone_domain bsp psu_cortexa53_0 include]
    file mkdir ${platform_bsp_include_dir}
    file delete -force [file join ${platform_bsp_include_dir} metal]
    file copy -force ${custom_metal_dir} ${platform_bsp_include_dir}

    set xparameters_overlay [file join ${app_src_dir} xparameters.h]
    set fp [open ${xparameters_overlay} w]
    puts $fp "#ifndef CUSTOM_XCZU47DR_XPARAMETERS_OVERLAY_H"
    puts $fp "#define CUSTOM_XCZU47DR_XPARAMETERS_OVERLAY_H"
    puts $fp "#include_next \"xparameters.h\""
    puts $fp "#ifndef XPAR_XRFDC_NUM_INSTANCES"
    puts $fp "#define XPAR_XRFDC_NUM_INSTANCES 1U"
    puts $fp "#endif"
    puts $fp "#ifndef XPAR_XRFDC_0_DEVICE_ID"
    puts $fp "#define XPAR_XRFDC_0_DEVICE_ID 0U"
    puts $fp "#endif"
    puts $fp "#ifndef XPAR_XRFDC_0_BASEADDR"
    puts $fp "#define XPAR_XRFDC_0_BASEADDR 0xA0040000U"
    puts $fp "#endif"
    puts $fp "#ifndef XPAR_XRFDC_0_DEV_NAME"
    puts $fp "#define XPAR_XRFDC_0_DEV_NAME \"rfdc_custom_xczu47dr_ip\""
    puts $fp "#endif"
    puts $fp "#endif"
    close $fp
}

# Build application
puts "Building application..."
app build -name ${app_name}

if {$board_define eq "BOARD_CUSTOM_XCZU47DR"} {
    set debug_dir [file join ${workspace_dir} ${app_name} Debug]
    set bsp_include_dir [file join ${workspace_dir} hw_platform export hw_platform sw hw_platform standalone_domain bspinclude include]
    if {[file exists ${debug_dir}]} {
        puts "Adding custom RFDC include path to generated makefiles..."
        add_include_to_app_makefiles ${debug_dir} ${app_src_dir} ${bsp_include_dir}
        puts "Rebuilding application with custom RFDC sources..."
        set make_output [exec make -C ${debug_dir} all 2>@1]
        puts ${make_output}
    }
}

if {![file exists "${workspace_dir}/${app_name}/Debug/makefile"]} {
    puts "Regenerating application makefiles..."
    app build -name ${app_name}
}

puts ""
puts "=========================================="
puts "Application created successfully!"
puts "ELF: ${workspace_dir}/${app_name}/Debug/${app_name}.elf"
puts "=========================================="
