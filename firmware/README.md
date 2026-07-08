# Firmware - Embedded Software

This directory contains the embedded firmware (PS code) for the XCZU47DR RFDC project.

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

The default firmware target is `TARGET=custom_xczu47dr`, which builds the
normal eight-output RFDC playback application. Use `TARGET=custom_xczu47dr_bw`
only for the standalone DDR bandwidth pressure application.

```bash
# Create application from XSA, first time
./build.sh create

# Build application after source changes
./build.sh build

# Rebuild from scratch
./build.sh rebuild

# Program FPGA and run
./build.sh program

# Clean workspace
./build.sh clean

# Preview create and program paths without XSCT or JTAG actions
DRY_RUN=1 ./build.sh create
DRY_RUN=1 ./build.sh program

# Build when the XSA is present
./build.sh create
./build.sh build
```

## Build Flow

1. **Create**: Creates Vitis platform and application from the target XSA.
2. **Build**: Compiles source code and generates the target ELF.
3. **Program**: Sources the generated PS init script, programs the target bitstream, downloads the ELF via JTAG, and starts Cortex-A53 #0.

## Build Outputs

Default `TARGET=custom_xczu47dr` outputs:

- **ELF file**: `workspace/custom_xczu47dr/rfdc_app/Debug/rfdc_app.elf`
- **Map file**: `workspace/custom_xczu47dr/rfdc_app/Debug/rfdc_app.elf.map`
- **PS init script**: `workspace/custom_xczu47dr/hw_platform/hw/psu_init.tcl`

`TARGET=custom_xczu47dr_bw` outputs:

- **ELF file**: `workspace/custom_xczu47dr_bandwidth/bandwidth_app/Debug/bandwidth_app.elf`
- **Map file**: `workspace/custom_xczu47dr_bandwidth/bandwidth_app/Debug/bandwidth_app.elf.map`
- **PS init script**: `workspace/custom_xczu47dr_bandwidth/hw_platform/hw/psu_init.tcl`

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
- `dma/`: DMA stubs (not used in current hardware)

## Custom XCZU47DR Firmware Notes

`TARGET=custom_xczu47dr` builds with `BOARD_CUSTOM_XCZU47DR` and uses `hardware/vivado/output/custom_xczu47dr_rfdc.xsa`, `hardware/vivado/output/custom_xczu47dr_rfdc.bit`, and `workspace/custom_xczu47dr`. The custom build produces a target-specific Vitis workspace and ELF for the eight-output DAC bring-up path.

The custom hardware debug trigger output is XS18 `TRIG_1`. The hardware wrapper is `TopCustomXczu47dr`, which drives that MMCX output from package ball A6 after host configuration commit so the END timing can be checked externally or through ILA.

For the custom target, the PL HMC7044 sequencer programs the clock chip before firmware starts RFDC, including the 128 MHz DAC refclk outputs used by the 9.6 GS/s RFDC configuration. Firmware does not drive any CLK104/LMK/LMX clock path, prints the custom clock policy, polls the HMC7044 done bit from AXI GPIO channel 2, and aborts if the sequencer does not complete. The RTL drives `RESET_H7044_H_0` low as the released state for the active-high reset net; verify that polarity on the board during bring-up.

The custom RFDC path uses CH1-CH8 -> DAC00/DAC02/DAC10/DAC12/DAC20/DAC22/DAC30/DAC32, with 6.4 GS/s DAC sampling, 16x interpolation, 400 MS/s complex I/Q input, and a 50 MHz RFDC fabric stream. Firmware starts enabled RFDC tiles, checks startup return values, and configures DAC VOP, Nyquist zone, and fine-NCO C2R mixer settings for tile/block pairs 0/0, 0/2, 1/0, 1/2, 2/0, 2/2, 3/0, and 3/2. The default role map is CH1-CH4 XY at NCO -1.9 GHz, CH5-CH6 Z at NCO 0 GHz with tile-230 DC coupling, and CH7-CH8 Readout at NCO -0.6/-0.2 GHz. The host can retune these through the DDR mailbox at offset `0x0FF00000` with magic `RFDCNCO0`. The PS Ethernet/lwIP server path is removed from the firmware; JTAG programming and board-level validation are still separate bring-up steps.

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
- PS Ethernet/lwIP support is removed from the firmware
- DMA functionality is stubbed (no AXI DMA in hardware)
- RFDC and clock configuration are the main features
