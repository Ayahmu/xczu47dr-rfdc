# Hardware - Chisel HDL

This directory contains the Chisel hardware description code for generating custom RTL modules.

## Directory Structure

```
chisel/
├── axidma/             # AXI DMA modules
├── common/             # Common utilities and components
├── gpio/               # GPIO modules
├── led/                # LED control modules
├── memory/             # Memory-related modules
├── Verilog/            # Pre-generated Verilog files
├── build.sc            # Mill build configuration
├── instant.py          # Quick elaboration script
├── postElaborating.py  # Post-elaboration processing
├── .mill-version       # Mill version specification
└── .scalafmt.conf      # Scala formatting configuration
```

## Prerequisites

- Java 11 or later
- Mill build tool
- Scala (managed by Mill)

## Quick Start

### Install Mill

```bash
# On Linux
curl -L https://github.com/com-lihaoyi/mill/releases/download/0.11.6/0.11.6 > mill
chmod +x mill
sudo mv mill /usr/local/bin/
```

### Generate Verilog

```bash
# Generate all modules
mill common.runMain <ModuleName>

# Or use the instant script
./instant.py <ModuleName>
```

### Example

```bash
# Generate GPIO module
mill gpio.runMain gpio.GPIO

# Generate with instant script
./instant.py gpio.GPIO
```

## Module Overview

- **axidma**: AXI DMA interface modules
- **common**: Shared utilities (buffers, delays, math functions, etc.)
- **gpio**: General Purpose I/O controllers
- **led**: LED control logic
- **memory**: Memory controllers and interfaces

## Integration with Vivado

Generated Verilog files can be added to the Vivado project:

1. Generate Verilog using Mill or instant.py
2. Copy generated `.v` files to `../vivado/src/`
3. Rebuild Vivado project

## Notes

- Generated Verilog files are in the `Verilog/` directory
- The build system uses Mill instead of SBT for faster builds
- Chisel version and dependencies are specified in `build.sc`
