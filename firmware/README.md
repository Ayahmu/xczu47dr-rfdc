# Firmware - Embedded Software

This directory contains the embedded firmware (PS code) for the ZCU216 RFDC project.

## Directory Structure

```
firmware/
├── src/                    # Source code
│   ├── main.c              # Main application
│   ├── main.h              # Main header
│   ├── platform/           # Platform initialization
│   ├── drivers/            # Custom drivers
│   ├── modules/            # Functional modules
│   │   ├── rf/             # RFDC and clock control
│   │   ├── net/            # Network stubs
│   │   └── dma/            # DMA stubs
│   ├── config/             # Configuration files
│   └── lscript.ld          # Linker script
├── scripts/                # Build scripts
│   ├── create_app.tcl      # Create Vitis application
│   └── program.tcl         # Program FPGA and download ELF
├── build.sh                # Build automation script
└── workspace/              # Vitis workspace (gitignored)
```

## Prerequisites

- Xilinx Vitis 2024.2
- Hardware XSA file from Vivado build
- ARM cross-compiler (aarch64-none-elf-gcc)

## Quick Start

### Setup Environment

```bash
source /tools/Xilinx/Vitis/2024.2/settings64.sh
```

### Build Commands

```bash
# Create application from XSA (first time)
./build.sh create

# Build application (after source changes)
./build.sh build

# Rebuild from scratch
./build.sh rebuild

# Program FPGA and run
./build.sh program

# Clean workspace
./build.sh clean
```

## Build Flow

1. **Create**: Creates Vitis platform and application from XSA
2. **Build**: Compiles source code and generates ELF
3. **Program**: Programs FPGA bitstream and downloads ELF via JTAG

## Build Outputs

- **ELF file**: `workspace/rfdc_app/Debug/rfdc_app.elf`
- **Map file**: `workspace/rfdc_app/Debug/rfdc_app.elf.map`

## Hardware Configuration

- **Processor**: ARM Cortex-A53 (psu_cortexa53_0)
- **OS**: Standalone (bare-metal)
- **Memory**: DDR4 @ 0x800000000
- **UART**: 115200 baud

## Source Code Overview

### Main Application
- `main.c/h`: Application entry point and main loop

### Platform
- `platform/platform_zynqmp.c`: Platform initialization (cache, clocks)

### Drivers
- Custom drivers for peripherals

### Modules
- `rf/`: RFDC control, LMK/LMX clock configuration
- `net/`: Network stubs (lwip disabled)
- `dma/`: DMA stubs (not used in current hardware)

## Debugging

### UART Console

```bash
# Linux
screen /dev/ttyUSB0 115200

# Or
minicom -D /dev/ttyUSB0 -b 115200
```

### XSCT Debug

```bash
xsct
xsct% connect
xsct% targets
xsct% mrd 0xA0010000 16    # Read memory
xsct% mwr 0xA0010000 0x1234 # Write memory
```

## Notes

- The firmware is built for bare-metal (no OS)
- Network functionality is disabled (no Ethernet MAC in hardware)
- DMA functionality is stubbed (no AXI DMA in hardware)
- RFDC and clock configuration are the main features
