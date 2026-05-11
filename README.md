# ZCU216 RFDC Project

Complete FPGA development project for Xilinx ZCU216 RFSoC board with RF Data Converter (RFDC) support.

## Project Structure

```
zcu216_rfdc_project/
├── hardware/           # FPGA hardware design
│   ├── chisel/        # Chisel HDL source code
│   └── vivado/        # Vivado project and scripts
├── firmware/          # ARM processor firmware
│   ├── src/          # Firmware source code
│   └── scripts/      # Vitis build scripts
└── software/          # Host control software
    └── host.py       # Python control script
```

## Hardware

### Chisel HDL Design

The hardware design is written in Chisel, a hardware construction language embedded in Scala.

**Build Chisel:**
```bash
cd hardware/chisel
mill chisel.runMain led.LedTop
```

This generates Verilog files in `hardware/chisel/generated/`.

**Requirements:**
- Mill build tool (version specified in `.mill-version`)
- Java 11 or later

### Vivado Project

The Vivado project integrates Chisel-generated Verilog with Xilinx IP cores.

**Build hardware:**
```bash
cd hardware/vivado
./build.sh          # Complete build (synthesis, implementation, bitstream)
./build.sh synth    # Synthesis only
./build.sh impl     # Implementation only
./build.sh bit      # Bitstream generation only
./build.sh xsa      # Export XSA file only
```

**Output:**
- Bitstream: `hardware/vivado/work/zcu216_rfdc.runs/impl_1/design_1_wrapper.bit`
- XSA file: `hardware/vivado/output/zcu216_rfdc.xsa`

**Requirements:**
- Xilinx Vivado 2024.2
- ZCU216 board files

## Firmware

ARM Cortex-A53 firmware for the PS (Processing System) side.

**Build firmware:**
```bash
cd firmware
source /tools/Xilinx/Vitis/2024.2/settings64.sh
./build.sh create   # Create Vitis application (first time)
./build.sh build    # Build application (incremental)
./build.sh rebuild  # Clean and rebuild from scratch
```

**Program FPGA:**
```bash
./build.sh program  # Program FPGA and download ELF via JTAG
```

**Output:**
- ELF file: `firmware/workspace/rfdc_app/Debug/rfdc_app.elf`

**Requirements:**
- Xilinx Vitis 2024.2
- XSA file from hardware build
- JTAG connection to ZCU216 board

### Firmware Features

- RFDC initialization and configuration
- GPIO control
- Clock configuration (LMK04828, LMX2594)
- Network communication (TCP/IP)
- DMA support

## Software

Python-based host control software for communicating with the board.

**Setup:**
```bash
cd software
pip install -r requirements.txt
```

**Usage:**
```python
from host import RFSocController

# Connect to board
controller = RFSocController(ip='192.168.1.10', port=7)

# Upload waveform data
import numpy as np
waveform = np.random.randint(-32768, 32767, 1024, dtype=np.int16)
controller.upload_waveform(waveform, ddr_addr=0x800000000)

# Send instructions
cmds = [
    [0x00000001, 0x00000000, 0x00000000, 0x00000000],  # Start command
]
controller.send_instructions(cmds)
```

## Development Workflow

### 1. Hardware Development

1. Modify Chisel source code in `hardware/chisel/`
2. Generate Verilog: `cd hardware/chisel && mill chisel.runMain <module>`
3. Build Vivado project: `cd hardware/vivado && ./build.sh`
4. Export XSA: `./build.sh xsa`

### 2. Firmware Development

1. Modify firmware source in `firmware/src/`
2. Build firmware: `cd firmware && ./build.sh build`
3. Program board: `./build.sh program`

### 3. Software Development

1. Modify `software/host.py`
2. Test with board: `python host.py`

## Board Configuration

**Target Board:** Xilinx ZCU216 (xczu49dr-ffvf1760-2-e)

**Key Components:**
- RF Data Converter (RFDC)
- ARM Cortex-A53 quad-core processor
- DDR4 memory
- GPIO
- Ethernet

## Debugging

### JTAG Debugging

Connect to board via XSCT:
```bash
xsct
connect
targets
# Select Cortex-A53 core
targets -set -filter {name =~ "Cortex-A53 #0"}
# Read memory
mrd 0xA0000000 10
# Write memory
mwr 0xA0000000 0x12345678
```

### Serial Console

Connect to UART (115200 8N1) to view firmware output.

## License

[Specify your license here]

## Contributors

[List contributors here]

## References

- [Xilinx ZCU216 Documentation](https://www.xilinx.com/products/boards-and-kits/zcu216.html)
- [Chisel Documentation](https://www.chisel-lang.org/)
- [Vitis Unified Software Platform](https://www.xilinx.com/products/design-tools/vitis.html)
