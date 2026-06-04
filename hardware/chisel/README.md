# Chisel Hardware Design

This directory contains Chisel (Constructing Hardware in a Scala Embedded Language) sources for custom hardware modules used in the ZCU216 RFDC project.

## Overview

Chisel is a hardware construction language embedded in Scala that enables:
- High-level hardware description with type safety
- Parameterizable and reusable hardware components
- Automatic generation of synthesizable Verilog
- Powerful testing framework (ChiselTest)

## Directory Structure

```
chisel/
├── build.sc           # Mill build configuration
├── build.sh           # Build automation script
├── .mill-version      # Mill version specification (0.11.6)
├── common/            # Common utilities and base classes
│   └── src/
├── led/               # LED controller module
│   └── src/
├── gpio/              # GPIO controller module
│   └── src/
├── axidma/            # AXI DMA module
│   └── src/
├── memory/            # Memory controller module
│   └── src/
├── out/               # Mill build outputs (auto-generated)
└── generated/         # Generated Verilog files (auto-generated)
```

## Prerequisites

### Required Tools

1. **Mill Build Tool** (version 0.11.6)
   ```bash
   # Check if Mill is installed
   mill --version
   
   # Install Mill if needed
   curl -L https://github.com/com-lihaoyi/mill/releases/download/0.11.6/0.11.6 > mill
   chmod +x mill
   sudo mv mill /usr/local/bin/
   ```

2. **Java JDK** (version 8 or higher)
   ```bash
   # Check Java version
   java -version
   
   # Should output Java 8 or higher
   ```

3. **Scala** (automatically managed by Mill)
   - Mill will download the correct Scala version
   - No manual installation needed

## Quick Start

### Generate All Modules

```bash
./build.sh all
```

This generates Verilog modules and generated Vivado Tcl configuration files in the `generated/` directory.

### Generate Specific Modules

```bash
# LED controller only
./build.sh led

# GPIO controller only
./build.sh gpio

# RFDC Vivado IP configuration only
./build.sh rfdc
```

### Clean Build Artifacts

```bash
./build.sh clean
```

## Build Script Usage

```bash
./build.sh {led|gpio|reset|glue|rfdc|all|clean}

Commands:
  led    - Generate LED module Verilog
  gpio   - Generate GPIO module Verilog
  reset  - Generate reset module Verilog
  glue   - Generate glue module Verilog
  rfdc   - Generate RFDC Vivado configuration Tcl
  all    - Generate all modules and RFDC Vivado configuration
  clean  - Remove build artifacts

Output directory: generated/
```

## Module Descriptions

### LED Controller (`led/`)

Simple LED blinker module for testing and debugging.

**Features:**
- Configurable blink frequency
- AXI-Lite slave interface for control
- Multiple LED outputs

**Generated Files:**
- `LedTop.v` - Top-level LED controller

**Parameters:**
- `clockFreq`: System clock frequency (Hz)
- `blinkFreq`: LED blink frequency (Hz)
- `numLeds`: Number of LED outputs

### GPIO Controller (`gpio/`)

Extended GPIO functionality with interrupt support.

**Features:**
- Configurable number of GPIO pins
- Input/output direction control
- Interrupt generation on pin changes
- AXI-Lite slave interface

**Generated Files:**
- `GPIOTop.v` - Top-level GPIO controller

**Parameters:**
- `numPins`: Number of GPIO pins
- `hasInterrupt`: Enable interrupt support

### RFDC Vivado Configuration (`rfdc/`)

Generates `generated/rfdc_custom_xczu47dr_config.tcl`, which is sourced by the
Vivado block-design script for `TARGET=custom_xczu47dr`. This keeps the RFDC as
the Xilinx `usp_rf_data_converter` hard IP while moving the custom-board RFDC
parameter set into the Chisel/Scala generation flow.

**Generated Files:**
- `rfdc_custom_xczu47dr_config.tcl` - DAC tile/slice enables, 125 MHz refclk,
  5.0 GS/s sampling, 312.5 MHz fabric clocks, and Zone2 settings.

### AXI DMA (`axidma/`)

High-performance DMA engine for data transfer between memory and streaming interfaces.

**Features:**
- AXI4 memory-mapped interface
- AXI-Stream data interface
- Scatter-gather support
- Configurable data width

**Generated Files:**
- `AxiDmaTop.v` - Top-level DMA controller

**Parameters:**
- `dataWidth`: Data bus width (bits)
- `addrWidth`: Address bus width (bits)

### Memory Controller (`memory/`)

Custom memory controller for specialized memory access patterns.

**Features:**
- Burst access support
- Configurable memory interface
- AXI4 compliant

**Generated Files:**
- `MemoryTop.v` - Top-level memory controller

## Manual Build with Mill

If you prefer to use Mill directly:

```bash
# List all available targets
mill resolve __

# Generate LED module
mill chisel.runMain led.LedTop

# Generate GPIO module
mill chisel.runMain gpio.GPIOTop

# Run tests (if available)
mill chisel.test

# Clean build artifacts
mill clean
```

## Development Workflow

### 1. Edit Chisel Sources

Modify Scala files in the appropriate module directory:
```bash
vim led/src/LedController.scala
```

### 2. Generate Verilog

```bash
./build.sh led
```

### 3. Verify Generated Verilog

```bash
cat generated/LedTop.v
```

### 4. Integrate with Vivado

The generated Verilog files are automatically picked up by the Vivado build:
```bash
cd ../vivado
./build.sh
```

## Testing

Chisel provides a powerful testing framework. To run tests:

```bash
# Run all tests
mill chisel.test

# Run specific test
mill chisel.test.testOnly led.LedControllerTest
```

## Generated Verilog

After running the build script, Verilog files are generated in `generated/`:

```
generated/
├── LedTop.v           # LED controller
├── GPIOTop.v          # GPIO controller
├── AxiDmaTop.v        # AXI DMA
└── MemoryTop.v        # Memory controller
```

These files are:
- **Synthesizable**: Ready for FPGA implementation
- **Readable**: Well-formatted with comments
- **Portable**: Standard Verilog compatible with any tool

## Chisel Language Features Used

### Bundles
Custom data types for grouping signals:
```scala
class AxiLiteBundle extends Bundle {
  val awaddr = Output(UInt(32.W))
  val awvalid = Output(Bool())
  val awready = Input(Bool())
  // ...
}
```

### Modules
Hardware components:
```scala
class LedController extends Module {
  val io = IO(new Bundle {
    val led = Output(UInt(8.W))
  })
  // Hardware logic here
}
```

### Registers
Sequential logic:
```scala
val counter = RegInit(0.U(32.W))
counter := counter + 1.U
```

### Conditional Logic
```scala
when(enable) {
  led := ~led
}.otherwise {
  led := 0.U
}
```

## Troubleshooting

### Mill Not Found

```bash
# Install Mill
curl -L https://github.com/com-lihaoyi/mill/releases/download/0.11.6/0.11.6 > mill
chmod +x mill
sudo mv mill /usr/local/bin/
```

### Java Version Issues

```bash
# Check Java version
java -version

# Install Java 11 (recommended)
sudo apt install openjdk-11-jdk  # Ubuntu/Debian
```

### Mill Version Mismatch

```bash
# Check required version
cat .mill-version

# Install specific version
curl -L https://github.com/com-lihaoyi/mill/releases/download/$(cat .mill-version)/$(cat .mill-version) > mill
chmod +x mill
sudo mv mill /usr/local/bin/
```

### Build Errors

```bash
# Clean and rebuild
./build.sh clean
./build.sh all

# Check Mill output for detailed errors
mill chisel.runMain led.LedTop
```

### Generated Verilog Issues

If generated Verilog has synthesis issues:
1. Check Chisel source for unsupported constructs
2. Verify parameter values are reasonable
3. Review Chisel documentation for synthesis guidelines

## Best Practices

### Code Organization
- Keep modules small and focused
- Use bundles for complex interfaces
- Parameterize for reusability

### Naming Conventions
- Module names: `PascalCase`
- Signal names: `camelCase`
- Constants: `UPPER_CASE`

### Documentation
- Add comments for complex logic
- Document module parameters
- Provide usage examples

### Version Control
- Commit Chisel sources (`.scala` files)
- **Do not commit** generated Verilog (in `.gitignore`)
- **Do not commit** build artifacts (`out/` directory)

## Resources

- [Chisel Official Website](https://www.chisel-lang.org/)
- [Chisel Bootcamp](https://github.com/freechipsproject/chisel-bootcamp)
- [Chisel Cheatsheet](https://github.com/freechipsproject/chisel-cheatsheet)
- [Mill Build Tool](https://mill-build.com/)
- [Scala Documentation](https://docs.scala-lang.org/)

## Next Steps

After generating Verilog:

1. **Verify Verilog**: Check generated files in `generated/`
2. **Build Vivado Project**: Run `cd ../vivado && ./build.sh`
3. **Simulate**: Use Vivado simulator or other tools
4. **Synthesize**: Integrate with complete FPGA design

## Contributing

When adding new Chisel modules:

1. Create new directory under `chisel/`
2. Add source files in `src/` subdirectory
3. Update `build.sc` with new module
4. Add build target to `build.sh`
5. Document module in this README
6. Test thoroughly before committing
