# Hardware Design

This directory contains the complete hardware design for the ZCU216 RFDC project, including Chisel HDL sources and Vivado FPGA implementation.

## Directory Structure

```
hardware/
├── chisel/              # Chisel hardware description language sources
│   ├── build.sc         # Mill build configuration
│   ├── build.sh         # Chisel build script
│   ├── .mill-version    # Mill version specification
│   ├── common/          # Common Chisel modules
│   ├── led/             # LED controller module
│   ├── gpio/            # GPIO controller module
│   ├── axidma/          # AXI DMA module
│   ├── memory/          # Memory controller module
│   └── generated/       # Generated Verilog output (auto-generated)
│
└── vivado/              # Vivado FPGA project
    ├── build.sh         # Complete build automation script
    ├── scripts/         # Vivado TCL scripts
    │   ├── create_project.tcl   # Project creation
    │   ├── run_synth.tcl        # Synthesis
    │   ├── run_impl.tcl         # Implementation
    │   ├── run_bitstream.tcl    # Bitstream generation
    │   └── export_xsa.tcl       # XSA export for firmware
    ├── bd/              # Block Design TCL scripts
    ├── src/             # Additional RTL sources
    ├── xdc/             # Constraint files
    ├── work/            # Vivado project workspace (auto-generated)
    └── output/          # Build outputs (bitstream, XSA)
```

## Prerequisites

### Chisel Build Requirements

- **Mill Build Tool**: Version specified in `.mill-version`
  ```bash
  # Install Mill (if not already installed)
  curl -L https://github.com/com-lihaoyi/mill/releases/download/0.11.6/0.11.6 > mill
  chmod +x mill
  sudo mv mill /usr/local/bin/
  ```

- **Java JDK**: Version 8 or higher
  ```bash
  java -version
  ```

### Vivado Requirements

- **Xilinx Vivado**: Version 2024.2
  ```bash
  # Source Vivado environment
  source /tools/Xilinx/Vivado/2024.2/settings64.sh
  ```

- **Target Device**: Zynq UltraScale+ xczu49dr-ffvf1760-2-e
- **Board**: Xilinx ZCU216 Evaluation Board

## Quick Start

### Complete Build (Chisel + Vivado)

Build everything from scratch:

```bash
cd hardware/vivado
./build.sh
```

This will:
1. Generate Verilog from Chisel sources
2. Create Vivado project
3. Run synthesis
4. Run implementation
5. Generate bitstream
6. Export XSA for firmware development

**Build time**: Approximately 30-60 minutes depending on your machine.

### Build Options

```bash
# Clean build (remove all previous outputs)
./build.sh --clean

# Skip Chisel generation (use existing Verilog)
./build.sh --skip-chisel

# Only create project (no synthesis/implementation)
./build.sh --skip-synth --skip-impl --skip-bitstream

# Show all options
./build.sh --help
```

## Step-by-Step Build

### 1. Generate Chisel Verilog

```bash
cd hardware/chisel

# Generate all modules
./build.sh all

# Or generate specific modules
./build.sh led
./build.sh gpio

# Clean Chisel build artifacts
./build.sh clean
```

**Output**: Verilog files in `chisel/generated/`

### 2. Create Vivado Project

```bash
cd hardware/vivado
vivado -mode batch -source scripts/create_project.tcl
```

**Output**: Vivado project in `vivado/work/zcu216_rfdc.xpr`

### 3. Run Synthesis

```bash
vivado -mode batch -source scripts/run_synth.tcl
```

**Output**: Synthesis reports in `work/zcu216_rfdc.runs/synth_1/reports/`

### 4. Run Implementation

```bash
vivado -mode batch -source scripts/run_impl.tcl
```

**Output**: Implementation reports in `work/zcu216_rfdc.runs/impl_1/reports/`

### 5. Generate Bitstream

```bash
vivado -mode batch -source scripts/run_bitstream.tcl
```

**Output**: `output/zcu216_rfdc.bit`

### 6. Export XSA

```bash
vivado -mode batch -source scripts/export_xsa.tcl
```

**Output**: `output/zcu216_rfdc.xsa` (used by firmware build)

## Hardware Architecture

### Block Design Components

- **Zynq UltraScale+ MPSoC**: ARM Cortex-A53 + Cortex-R5 + Mali GPU
- **RF Data Converter (RFDC)**: High-speed ADC/DAC for RF signal processing
- **AXI Interconnect**: High-performance bus for PS-PL communication
- **AXI DMA**: Direct memory access for efficient data transfer
- **GPIO**: General purpose I/O for control signals
- **Custom Chisel Modules**: LED controller, GPIO extensions, etc.

### Memory Map

| Component | Base Address | Size |
|-----------|--------------|------|
| M_AXI_GPIO | 0xA0010000 | 64KB |
| RFDC | 0xA0000000 | 64KB |
| DDR4 | 0x800000000 | 4GB |

## Chisel Modules

### LED Controller (`led/`)
- Simple LED blinker for testing
- Configurable blink frequency
- AXI-Lite interface

### GPIO Controller (`gpio/`)
- Extended GPIO functionality
- Interrupt support
- AXI-Lite interface

### AXI DMA (`axidma/`)
- High-performance data transfer
- Scatter-gather support
- AXI-Stream interface

## Build Outputs

After a successful build, you will find:

```
vivado/output/
├── zcu216_rfdc.bit      # FPGA bitstream (~30MB)
├── zcu216_rfdc.ltx      # Debug probes (if ILA/VIO used)
└── zcu216_rfdc.xsa      # Hardware platform for Vitis (~12MB)
```

## Troubleshooting

### Chisel Build Issues

**Problem**: Mill not found
```bash
# Solution: Install Mill
curl -L https://github.com/com-lihaoyi/mill/releases/download/0.11.6/0.11.6 > mill
chmod +x mill
sudo mv mill /usr/local/bin/
```

**Problem**: Java version mismatch
```bash
# Solution: Check Java version
java -version
# Should be Java 8 or higher
```

### Vivado Build Issues

**Problem**: Vivado not found
```bash
# Solution: Source Vivado settings
source /tools/Xilinx/Vivado/2024.2/settings64.sh
```

**Problem**: Synthesis/Implementation fails
```bash
# Solution: Check reports for errors
cat vivado/work/zcu216_rfdc.runs/synth_1/reports/post_synth_timing.rpt
cat vivado/work/zcu216_rfdc.runs/impl_1/reports/post_impl_timing.rpt
```

**Problem**: Timing not met
- Review timing reports
- Adjust clock constraints in XDC files
- Consider adding pipeline stages in critical paths

**Problem**: Resource utilization too high
- Check utilization reports
- Optimize Chisel/RTL code
- Consider using different optimization strategies

## Development Workflow

### Iterative Development

1. **Modify Chisel sources** in `chisel/`
2. **Regenerate Verilog**: `cd chisel && ./build.sh all`
3. **Update Vivado project**: `cd vivado && ./build.sh --skip-synth --skip-impl`
4. **Run synthesis**: `vivado -mode batch -source scripts/run_synth.tcl`
5. **Check timing/utilization** in reports
6. **Iterate** until design meets requirements

### GUI Development

For interactive development, open the project in Vivado GUI:

```bash
cd hardware/vivado
vivado work/zcu216_rfdc.xpr
```

## Performance Metrics

Typical resource utilization (post-implementation):

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| LUT | ~50K | 425K | ~12% |
| FF | ~80K | 850K | ~9% |
| BRAM | ~100 | 1080 | ~9% |
| DSP | ~50 | 1248 | ~4% |

Timing (typical):

- **Clock**: 250 MHz (4ns period)
- **Worst Negative Slack (WNS)**: > 0.5ns
- **Total Negative Slack (TNS)**: 0ns

## Next Steps

After hardware build completes:

1. **Firmware Development**: Use `output/zcu216_rfdc.xsa` to build ARM firmware
   ```bash
   cd ../../firmware
   ./build.sh
   ```

2. **Program FPGA**: Use Vivado Hardware Manager or XSCT
   ```bash
   cd ../../firmware
   xsct scripts/program.tcl
   ```

3. **Software Development**: Run host control software
   ```bash
   cd ../../software
   python host.py
   ```

## References

- [Chisel Documentation](https://www.chisel-lang.org/)
- [Mill Build Tool](https://mill-build.com/)
- [Vivado Design Suite User Guide](https://www.xilinx.com/support/documentation/sw_manuals/xilinx2024_2/ug892-vivado-design-flows-overview.pdf)
- [ZCU216 Evaluation Board User Guide](https://www.xilinx.com/support/documentation/boards_and_kits/zcu216/ug1390-zcu216-eval-bd.pdf)
- [Zynq UltraScale+ Device Technical Reference Manual](https://www.xilinx.com/support/documentation/user_guides/ug1085-zynq-ultrascale-trm.pdf)
