# ZCU216 RFDC Project

FPGA, bare-metal firmware, and host-control project for the Xilinx ZCU216 RFSoC board with RF Data Converter support.

## Project Layout

```text
zcu216_rfdc_project/
├── Makefile              # Top-level build, program, and host-control entry point
├── hardware/
│   ├── chisel/           # Chisel sources and generated RTL flow
│   └── vivado/           # Vivado BD, RTL shims, constraints, and build scripts
├── firmware/
│   ├── src/              # Cortex-A53 bare-metal firmware sources
│   ├── scripts/          # Vitis/XSCT platform, app, and JTAG scripts
│   └── build.sh          # Firmware build helper
└── software/
    ├── host.py           # Host-side waveform/control utility
    └── requirements.txt
```

## Top-Level Workflow

Source the Xilinx tools first so `vivado` and `xsct` are on `PATH`, then use the root `Makefile` as the primary interface.

```bash
# Full hardware and firmware build
make all

# Build only FPGA artifacts: Chisel RTL, Vivado project, synth, impl, bitstream, XSA
make hardware

# Build only firmware from the current XSA
make firmware

# Verify expected handoff artifacts exist
make artifacts

# Program the ZCU216 over JTAG with the default bitstream and ELF
make run

# Program with an explicit ELF or explicit BIT/ELF pair
make run zcu216 /path/to/rfdc_app.elf
make run BIT=/path/to/zcu216_rfdc.bit ELF=/path/to/rfdc_app.elf

# Run host-side waveform upload/control against the board
make host IP=10.87.5.241 PORT=7

# Offline host validation without board access
make host-dry-run
```

Default handoff artifacts:

- Bitstream: `hardware/vivado/output/zcu216_rfdc.bit`
- Debug probes: `hardware/vivado/output/zcu216_rfdc.ltx`
- Hardware handoff: `hardware/vivado/output/zcu216_rfdc.xsa`
- Firmware ELF: `firmware/workspace/rfdc_app/Debug/rfdc_app.elf`
- PS init script: `firmware/workspace/hw_platform/hw/psu_init.tcl`

`make run` requires a connected ZCU216 JTAG target. It programs the FPGA with the `.bit`, runs PS initialization from `psu_init.tcl`, downloads the ELF to `Cortex-A53 #0`, and starts execution. Use UART at 115200 baud to inspect firmware output.

## Requirements

- Vivado 2024.2
- Vitis/XSCT 2024.2
- ZCU216 board files
- Mill 0.11.6 and Java for Chisel generation
- Python 3 with packages from `software/requirements.txt`

Typical environment setup:

```bash
source /tools/Xilinx/Vivado/2024.2/settings64.sh
source /tools/Xilinx/Vitis/2024.2/settings64.sh
```

## Component Notes

- Hardware generation starts in `hardware/chisel` and is integrated by `hardware/vivado/scripts/create_project.tcl`.
- Vivado scripts under `hardware/vivado/scripts/` are the canonical Vivado entry points. Generated Vivado work directories and logs are ignored.
- Firmware creation uses `firmware/scripts/create_app.tcl`, which creates the Vitis hardware platform and application from the XSA.
- Host control uses `software/host.py`; use `--dry-run` or `make host-dry-run` for offline validation.

## Cleanup

Generated build state is intentionally excluded from version control. To remove local generated state without touching sources:

```bash
make clean
```

This removes Vivado work/output artifacts and the Vitis workspace. Recreate them with `make hardware` and `make firmware`.
