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
- Hardware XSA and bitstream from Vivado build
- ARM cross-compiler (aarch64-none-elf-gcc)

## Quick Start

### Setup Environment

```bash
source /tools/Xilinx/Vitis/2024.2/settings64.sh
```

### Build Commands

The default firmware target is `TARGET=zcu216`. Set `TARGET=custom_xczu47dr` for the custom XCZU47DR offline migration flow.

```bash
# Create application from XSA, first time, default ZCU216
./build.sh create
TARGET=zcu216 ./build.sh create

# Build application after source changes, default ZCU216
./build.sh build
TARGET=zcu216 ./build.sh build

# Rebuild from scratch, default ZCU216
./build.sh rebuild

# Program FPGA and run, default ZCU216
./build.sh program

# Clean default workspace
./build.sh clean

# Preview custom target create and program paths without XSCT or JTAG actions
DRY_RUN=1 TARGET=custom_xczu47dr ./build.sh create
DRY_RUN=1 TARGET=custom_xczu47dr ./build.sh program

# Build the custom target when its XSA is present
TARGET=custom_xczu47dr ./build.sh create
TARGET=custom_xczu47dr ./build.sh build
```

## Build Flow

1. **Create**: Creates Vitis platform and application from the target XSA.
2. **Build**: Compiles source code and generates the target ELF.
3. **Program**: Sources the generated PS init script, programs the target bitstream, downloads the ELF via JTAG, and starts Cortex-A53 #0.

## Build Outputs

Default `TARGET=zcu216` outputs:

- **ELF file**: `workspace/rfdc_app/Debug/rfdc_app.elf`
- **Map file**: `workspace/rfdc_app/Debug/rfdc_app.elf.map`
- **PS init script**: `workspace/hw_platform/hw/psu_init.tcl`

Custom `TARGET=custom_xczu47dr` outputs:

- **ELF file**: `workspace/custom_xczu47dr/rfdc_app/Debug/rfdc_app.elf`
- **Map file**: `workspace/custom_xczu47dr/rfdc_app/Debug/rfdc_app.elf.map`
- **PS init script**: `workspace/custom_xczu47dr/hw_platform/hw/psu_init.tcl`

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
- `rf/`: RFDC control and board clock policy
- `net/`: Network stubs (lwip disabled)
- `dma/`: DMA stubs (not used in current hardware)

## Custom XCZU47DR Firmware Notes

`TARGET=custom_xczu47dr` builds with `BOARD_CUSTOM_XCZU47DR` and uses `hardware/vivado/output/custom_xczu47dr_rfdc.xsa`, `hardware/vivado/output/custom_xczu47dr_rfdc.bit`, and `workspace/custom_xczu47dr`. This flow is for offline migration and minimal bring up preparation. It is not a claim that the custom board has been programmed, validated, or hardware-tested.

The custom hardware trigger pair is `EXT_TRIGGER_P/N`. The hardware wrapper is `TopCustomXczu47dr`, which maps that pair into the legacy `Top.trigger_in` path. The confirmed package balls are AR7 for `EXT_TRIGGER_P` and AR6 for `EXT_TRIGGER_N`.

The HMC7044 register and frequency table is not implemented. For the custom target, firmware bypasses the ZCU216 CLK104, LMK, and LMX programming path and prints a policy message. The custom Vivado flow now assumes the board supplies the required RFDC clock on the DAC2 clock pins and limits first bring-up to DAC20 and DAC22 only; ADC capture and DAC30 are deferred until board clock/channel validation.

The custom offline Vivado project can now be created with top `TopCustomXczu47dr` and part `xczu47dr-ffvg1517-2-i`. Firmware still depends on a generated custom XSA/BSP before a full C build can be claimed, and JTAG programming has not been run.

Deferred custom-board interfaces include PCIe, QSFP, SFP, Type-C, Aurora, and extra PL DDR unless later work requests them.

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
