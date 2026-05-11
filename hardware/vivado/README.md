# Hardware - Vivado Project

This directory contains the Vivado project files for the ZCU216 RFDC design.

## Directory Structure

```
vivado/
├── bd/                 # Block Design TCL scripts
├── scripts/            # IP configuration scripts
├── src/                # Verilog/SystemVerilog source files
├── xdc/                # Constraint files
├── build.tcl           # Main project creation script
├── build.sh            # Build automation wrapper
├── run_synth.tcl       # Synthesis script
├── run_impl.tcl        # Implementation script
├── run_bitstream.tcl   # Bitstream generation script
├── export_xsa.tcl      # XSA export script
├── work/               # Generated project files (gitignored)
└── output/             # Build outputs (gitignored)
```

## Prerequisites

- Xilinx Vivado 2024.2
- ZCU216 board files installed

## Quick Start

### Setup Environment

```bash
source /tools/Xilinx/Vivado/2024.2/settings64.sh
```

### Build Commands

```bash
# Create project from TCL scripts
./build.sh create

# Run synthesis
./build.sh synth

# Run implementation
./build.sh impl

# Generate bitstream
./build.sh bitstream

# Export XSA for firmware development
./build.sh xsa

# Run complete build flow
./build.sh all

# Open in GUI
./build.sh gui

# Clean build artifacts
./build.sh clean
```

## Build Outputs

After successful build:
- **Bitstream**: `work/zcu216_rfdc.runs/impl_1/design_1_wrapper.bit`
- **XSA**: `output/zcu216_rfdc.xsa`

## Design Overview

- **Target Device**: xczu49dr-ffvf1760-2-e (ZCU216)
- **Block Design**: design_1.bd
- **Top Module**: design_1_wrapper

## Notes

- The `work/` directory contains all generated Vivado project files
- The `output/` directory contains final build artifacts (bitstream, XSA)
- Both directories are excluded from version control
