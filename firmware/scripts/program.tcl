#!/usr/bin/env xsct
# Program FPGA and Download ELF
# Usage: xsct program.tcl <xsa_file> <elf_file>

if {$argc != 2} {
    puts "Usage: xsct program.tcl <xsa_file> <elf_file>"
    puts "Example: xsct program.tcl ../hardware/vivado/output/zcu216_rfdc.xsa workspace/rfdc_app/Debug/rfdc_app.elf"
    exit 1
}

set xsa_file [lindex $argv 0]
set elf_file [lindex $argv 1]

puts "=========================================="
puts "Programming FPGA"
puts "=========================================="
puts "XSA: ${xsa_file}"
puts "ELF: ${elf_file}"
puts ""

# Connect to target
puts "Connecting to target..."
connect

# List available targets
puts "Available targets:"
targets

# Reset system
puts "Resetting system..."
targets -set -filter {name =~ "PSU"}
rst -system

# Program FPGA
puts "Programming FPGA..."
fpga ${xsa_file}

# Download ELF to A53 core
puts "Downloading ELF to A53 #0..."
targets -set -filter {name =~ "Cortex-A53 #0"}
dow ${elf_file}

# Start execution
puts "Starting execution..."
con

puts ""
puts "=========================================="
puts "Programming complete!"
puts "=========================================="
puts "Connect to UART at 115200 baud to see output"
