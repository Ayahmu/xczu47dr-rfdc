# Vivado FPGA Project

This directory contains the Vivado project for implementing the ZCU216 RFDC design on the Zynq UltraScale+ FPGA.

## Overview

The Vivado project integrates:
- Chisel-generated Verilog modules
- Xilinx IP cores (RFDC, AXI interconnect, etc.)
- Block Design for PS-PL integration
- Constraint files for timing and pinout
- Build automation scripts

## Directory Structure

```
vivado/
├── build.sh              # Complete build automation script
├── scripts/              # Vivado TCL scripts
│   ├── create_project.tcl    # Project creation
│   ├── run_synth.tcl         # Synthesis
│   ├── run_impl.tcl          # Implementation
│   ├── run_bitstream.tcl     # Bitstream generation
│   └── export_xsa.tcl        # XSA export
├── bd/                   # Block Design TCL scripts
│   └── design_1.tcl      # Main block design
├── src/                  # Additional RTL sources
├── xdc/                  # Constraint files
│   └── pin.xdc           # Board and timing constraints
├── work/                 # Vivado project workspace (auto-generated, ignored)
└── output/               # Build outputs (auto-generated, ignored)
    ├── zcu216_rfdc.bit   # FPGA bitstream
    ├── zcu216_rfdc.ltx   # Debug probes
    └── zcu216_rfdc.xsa   # Hardware platform
```

## Prerequisites

### Required Software

- **Xilinx Vivado**: Version 2024.2
  ```bash
  # Source Vivado environment
  source /tools/Xilinx/Vivado/2024.2/settings64.sh
  
  # Verify installation
  vivado -version
  ```

### Target Hardware

- **Device**: xczu49dr-ffvf1760-2-e
- **Board**: Xilinx ZCU216 Evaluation Board
- **Speed Grade**: -2

### Disk Space Requirements

- **Project workspace**: ~5 GB
- **Build outputs**: ~500 MB
- **Total recommended**: 10 GB free space

## Quick Start

### Complete Build

Run the complete build process (Chisel -> Synthesis -> Implementation -> Bitstream/XSA):

```bash
./build.sh
```

**Estimated time**: 30-60 minutes

### Build with Options

```bash
# Clean build (remove all previous outputs)
./build.sh --clean

# Skip Chisel generation (use existing Verilog)
./build.sh --skip-chisel

# Only create project (no synthesis)
./build.sh --skip-synth --skip-impl --skip-bitstream

# Show help
./build.sh --help
```

## Step-by-Step Build

### Step 1: Generate Chisel Verilog

```bash
cd ../chisel
./build.sh all
cd ../vivado
```

**Output**: Verilog files in `../chisel/generated/` (auto-generated, ignored)

### Step 2: Create Vivado Project

```bash
vivado -mode batch -source scripts/create_project.tcl
```

**What it does**:
- Creates new Vivado project
- Sets device and board properties
- Adds Chisel-generated Verilog
- Adds RTL sources from `src/`
- Adds constraint files from `xdc/`
- Creates Block Design from `bd/design_1.tcl`
- Generates HDL wrapper

**Output**: `work/zcu216_rfdc.xpr`

### Step 3: Run Synthesis

```bash
vivado -mode batch -source scripts/run_synth.tcl
```

**What it does**:
- Elaborates design
- Optimizes logic
- Maps to FPGA primitives
- Generates resource utilization report
- Generates timing report

**Output**: 
- Synthesized design in `work/zcu216_rfdc.runs/synth_1/`
- Reports in `work/zcu216_rfdc.runs/synth_1/reports/`

**Typical synthesis time**: 10-15 minutes

### Step 4: Run Implementation

```bash
vivado -mode batch -source scripts/run_impl.tcl
```

**What it does**:
- Places logic on FPGA
- Routes connections
- Optimizes timing
- Generates detailed reports

**Output**:
- Implemented design in `work/zcu216_rfdc.runs/impl_1/`
- Reports in `work/zcu216_rfdc.runs/impl_1/reports/`

**Typical implementation time**: 15-30 minutes

### Step 5: Generate Bitstream

```bash
vivado -mode batch -source scripts/run_bitstream.tcl
```

**What it does**:
- Generates FPGA configuration bitstream
- Copies bitstream to `output/`
- Copies debug probes (if ILA/VIO used)

**Output**: `output/zcu216_rfdc.bit` (~30 MB)

**Typical bitstream time**: 5-10 minutes

### Step 6: Export XSA

```bash
vivado -mode batch -source scripts/export_xsa.tcl
```

**What it does**:
- Exports hardware platform with bitstream
- Includes PS configuration
- Includes address map

**Output**: `output/zcu216_rfdc.xsa` (~12 MB)

This XSA file is used by Vitis to build ARM firmware.

## Build Outputs

After successful build:

```
output/
├── zcu216_rfdc.bit      # FPGA bitstream (~30 MB)
├── zcu216_rfdc.ltx      # Debug probes (if ILA/VIO used)
└── zcu216_rfdc.xsa      # Hardware platform (~12 MB)
```

### Bitstream (.bit)
- Binary configuration file for FPGA
- Used to program the device
- Contains complete FPGA configuration

### Debug Probes (.ltx)
- Logic analyzer probe definitions
- Used with Vivado Hardware Manager
- Only generated if ILA/VIO cores are used

### XSA (.xsa)
- Hardware platform archive
- Contains hardware specification
- Used by Vitis for firmware development
- Includes PS configuration and address map

## Design Architecture

### Block Design Components

The main block design (`bd/design_1.tcl`) includes:

#### Processing System (PS)
- **Zynq UltraScale+ MPSoC**
  - 4x ARM Cortex-A53 @ 1.2 GHz
  - 2x ARM Cortex-R5 @ 500 MHz
  - Mali-400 GPU
  - DDR4 memory controller

#### Programmable Logic (PL)
- **RF Data Converter (RFDC)**
  - 8x ADC channels @ 4 GSPS
  - 8x DAC channels @ 6.4 GSPS
  - Digital up/down conversion
  
- **AXI Interconnect**
  - High-performance PS-PL bridge
  - Multiple master/slave ports
  - Automatic width/clock conversion

- **AXI DMA**
  - Scatter-gather DMA
  - Memory-mapped to stream
  - Stream to memory-mapped

- **GPIO Controllers**
  - AXI GPIO IP
  - Custom Chisel GPIO modules
  - Interrupt support

- **Custom Chisel Modules**
  - LED controller
  - Additional GPIO
  - Custom logic

### Memory Map

| Component | Base Address | Size | Description |
|-----------|--------------|------|-------------|
| RFDC | 0xA0000000 | 64KB | RF Data Converter control |
| M_AXI_GPIO | 0xA0010000 | 64KB | GPIO control registers |
| AXI_DMA | 0xA0020000 | 64KB | DMA control registers |
| DDR4 | 0x00000000 | 2GB | Low DDR memory |
| DDR4 High | 0x800000000 | 2GB | High DDR memory |

### Clock Domains

| Clock | Frequency | Source | Usage |
|-------|-----------|--------|-------|
| pl_clk0 | 100 MHz | PS | AXI control interfaces |
| pl_clk1 | 250 MHz | PS | High-speed data path |
| rfdc_clk | 245.76 MHz | RFDC | RF data converter |

## Reports and Analysis

### Synthesis Reports

Located in `work/zcu216_rfdc.runs/synth_1/reports/`:

- **post_synth_util.rpt**: Resource utilization
  - LUT, FF, BRAM, DSP usage
  - Percentage of available resources

- **post_synth_timing.rpt**: Timing summary
  - Worst Negative Slack (WNS)
  - Total Negative Slack (TNS)
  - Clock domain analysis

### Implementation Reports

Located in `work/zcu216_rfdc.runs/impl_1/reports/`:

- **post_impl_util.rpt**: Final resource utilization
- **post_impl_timing.rpt**: Final timing analysis
- **post_impl_power.rpt**: Power consumption estimate
- **post_impl_drc.rpt**: Design Rule Check results

### Typical Resource Utilization

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| LUT | ~50,000 | 425,152 | ~12% |
| FF | ~80,000 | 850,304 | ~9% |
| BRAM | ~100 | 1,080 | ~9% |
| DSP | ~50 | 1,248 | ~4% |
| BUFG | ~10 | 544 | ~2% |

### Timing Performance

- **Target Clock**: 250 MHz (4.0 ns period)
- **Typical WNS**: +0.5 to +1.0 ns
- **Typical TNS**: 0 ns (no violations)

## GUI Development

For interactive development, open the project in Vivado GUI:

```bash
vivado work/zcu216_rfdc.xpr &
```

### Common GUI Tasks

#### View Block Design
1. Open project
2. Click "Open Block Design" in Flow Navigator
3. Edit design graphically

#### Run Synthesis
1. Click "Run Synthesis" in Flow Navigator
2. Wait for completion
3. View reports

#### Analyze Timing
1. Open synthesized/implemented design
2. Reports → Timing → Report Timing Summary
3. Analyze critical paths

#### Debug with ILA
1. Add ILA cores to design
2. Connect signals to debug
3. Generate bitstream
4. Open Hardware Manager
5. Program device and capture waveforms

## Constraint Files

The active Vivado constraints live in `xdc/pin.xdc`. This file contains the board-level and timing constraints used by `scripts/create_project.tcl`.

Key conventions:

- Use `-quiet` on constraints that refer to generated BD pins or clocks, so project creation remains robust across regenerated Vivado metadata.
- Keep board-specific pin and clock constraints in `pin.xdc`; do not create parallel `timing.xdc` or `pinout.xdc` files unless the build scripts are updated to include and document them.
- Validate constraint changes with `make hardware` or the step targets `make synth` and `make impl`.

## Troubleshooting

### Vivado Not Found

```bash
# Source Vivado settings
source /tools/Xilinx/Vivado/2024.2/settings64.sh

# Add to ~/.bashrc for permanent setup
echo 'source /tools/Xilinx/Vivado/2024.2/settings64.sh' >> ~/.bashrc
```

### Synthesis Fails

**Check synthesis log**:
```bash
cat work/zcu216_rfdc.runs/synth_1/runme.log
```

**Common issues**:
- Missing source files → Check `create_project.tcl`
- Syntax errors in Verilog → Check Chisel generation
- Unsupported constructs → Review Verilog code

### Timing Violations

**View timing report**:
```bash
cat work/zcu216_rfdc.runs/impl_1/reports/post_impl_timing.rpt
```

**Solutions**:
- Add pipeline stages in critical paths
- Adjust clock constraints
- Use faster speed grade
- Optimize logic in RTL

### Resource Overflow

**View utilization report**:
```bash
cat work/zcu216_rfdc.runs/impl_1/reports/post_impl_util.rpt
```

**Solutions**:
- Reduce design complexity
- Share resources
- Use different optimization strategy
- Consider larger device

### Block Design Issues

**Regenerate Block Design**:
```bash
vivado -mode batch -source bd/design_1.tcl
```

**Common issues**:
- IP version mismatch → Upgrade IP
- Connection errors → Check address map
- Validation errors → Review IP configuration

## Optimization Strategies

### Synthesis Strategies

Available in `run_synth.tcl`:
- **Default**: Balanced optimization
- **Flow_PerfOptimized_high**: Maximum performance
- **Flow_AreaOptimized_high**: Minimum area
- **Flow_RuntimeOptimized**: Fast compilation

### Implementation Strategies

Available in `run_impl.tcl`:
- **Default**: Balanced optimization
- **Performance_Explore**: Explore timing optimization
- **Area_Explore**: Explore area optimization
- **Congestion_SpreadLogic_high**: Reduce routing congestion

## Advanced Features

### Incremental Compilation

Speed up builds by reusing previous results:
```tcl
set_property INCREMENTAL_CHECKPOINT previous_run.dcp [get_runs impl_1]
```

### Out-of-Context Synthesis

Synthesize modules independently:
```tcl
create_run ooc_synth -flow {Vivado Synthesis 2024} -strategy "Flow_PerfOptimized_high"
```

### Partial Reconfiguration

Enable dynamic FPGA reconfiguration:
```tcl
set_property HD.RECONFIGURABLE true [get_cells reconfig_module]
```

## Next Steps

After successful hardware build:

1. **Verify Outputs**
   ```bash
   ls -lh output/
   ```

2. **Build Firmware**
   ```bash
   cd ../../firmware
   ./build.sh
   ```

3. **Program FPGA**
   ```bash
   cd ../../firmware
   ./build.sh program
   ```

## References

- [Vivado Design Suite User Guide](https://www.xilinx.com/support/documentation/sw_manuals/xilinx2024_2/ug892-vivado-design-flows-overview.pdf)
- [ZCU216 Board User Guide](https://www.xilinx.com/support/documentation/boards_and_kits/zcu216/ug1390-zcu216-eval-bd.pdf)
- [Zynq UltraScale+ Technical Reference](https://www.xilinx.com/support/documentation/user_guides/ug1085-zynq-ultrascale-trm.pdf)
- [Vivado TCL Commands](https://www.xilinx.com/support/documentation/sw_manuals/xilinx2024_2/ug835-vivado-tcl-commands.pdf)
