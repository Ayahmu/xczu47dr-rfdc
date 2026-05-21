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

Source the Xilinx tools first so `vivado` and `xsct` are on `PATH`, then use the root `Makefile` as the primary interface. The default target is `TARGET=zcu216`. Use `TARGET=custom_xczu47dr` for the offline custom XCZU47DR migration flow.

```bash
# Full default ZCU216 hardware and firmware build
make all
TARGET=zcu216 make all

# Full custom XCZU47DR hardware and firmware build
TARGET=custom_xczu47dr make all

# Build only FPGA artifacts: Chisel RTL, Vivado project, synth, impl, bitstream, XSA
make hardware
TARGET=zcu216 make hardware
TARGET=custom_xczu47dr make hardware

# Build only firmware from the current XSA
make firmware
TARGET=zcu216 make firmware
TARGET=custom_xczu47dr make firmware

# Verify expected handoff artifacts exist
make artifacts
TARGET=custom_xczu47dr make artifacts

# Program the ZCU216 over JTAG with the default target bitstream and ELF
make run
TARGET=zcu216 make run

# Select the custom target, or program with explicit artifacts
TARGET=custom_xczu47dr make run
make run BIT=/path/to/top.bit ELF=/path/to/app.elf PSU_INIT=/path/to/psu_init.tcl

# Preview custom firmware create and program paths without XSCT or JTAG actions
cd firmware
DRY_RUN=1 TARGET=custom_xczu47dr ./build.sh create
DRY_RUN=1 TARGET=custom_xczu47dr ./build.sh program

# Run host-side waveform upload/control against the board
make host IP=10.87.5.241 PORT=7

# Offline host validation without board access
make host-dry-run
```

Default `TARGET=zcu216` handoff artifacts:

- Bitstream: `hardware/vivado/output/zcu216_rfdc.bit`
- Debug probes: `hardware/vivado/output/zcu216_rfdc.ltx`
- Hardware handoff: `hardware/vivado/output/zcu216_rfdc.xsa`
- Firmware ELF: `firmware/workspace/rfdc_app/Debug/rfdc_app.elf`
- PS init script: `firmware/workspace/hw_platform/hw/psu_init.tcl`

Custom `TARGET=custom_xczu47dr` handoff artifacts:

- Bitstream: `hardware/vivado/output/custom_xczu47dr_rfdc.bit`
- Debug probes: `hardware/vivado/output/custom_xczu47dr_rfdc.ltx`
- Hardware handoff: `hardware/vivado/output/custom_xczu47dr_rfdc.xsa`
- Firmware ELF: `firmware/workspace/custom_xczu47dr/rfdc_app/Debug/rfdc_app.elf`
- PS init script: `firmware/workspace/custom_xczu47dr/hw_platform/hw/psu_init.tcl`

`make run` requires a connected ZCU216 JTAG target. It programs the FPGA with the `.bit`, runs PS initialization from `psu_init.tcl`, downloads the ELF to `Cortex-A53 #0`, and starts execution. Use UART at 115200 baud to inspect firmware output. The custom target is an offline migration and bring up flow pending verified HMC7044 and RFDC settings plus hardware validation.

## Custom XCZU47DR Bring-Up Scope

`TARGET=custom_xczu47dr` selects the `xczu47dr-ffvg1517-2-i` part without a Vivado `board_part`, uses `hardware/vivado/xdc/custom_xczu47dr_minimal.xdc`, and selects the `TopCustomXczu47dr` wrapper. The wrapper receives the custom board `EXT_TRIGGER_P/N` pair and feeds the legacy `Top.trigger_in` path. Schematic page 14 maps `EXT_TRIGGER_P` to package ball AR7 and `EXT_TRIGGER_N` to package ball AR6.

The current custom scope is intentionally small: part selection, minimal trigger IO, target specific Vivado artifacts, target specific Vitis workspace paths, and firmware build/program dry runs. The first hardware-oriented custom bring-up enables only DAC tile 2 slices 20 and 22, exposed as `vout20` and `vout22`, driven by the existing two waveform channels. PCIe, QSFP, SFP, Type-C, Aurora, extra PL DDR, ADC capture, DAC3/slice 30, LEDs, and other board interfaces are deferred unless they are requested later.

The user-provided reference project `/home/kyu/workspace/fpga_rfsoc_zjdx_20260503_jiaofu` is also built for `xczu47dr-ffvg1517-2-i`. Its generated RFDC XCI uses DAC tile 2 slices 20/22 with `DAC2_Sampling_Rate=1`, `DAC2_Refclk_Freq=125.000`, `DAC2_Outclk_Freq=15.625`, and interpolation mode `1`. The custom target now mirrors those simpler DAC2 RFDC values and makes the corresponding AXIS/`clk_dac2` metadata target-aware.

Two items are still decision needed before hardware claims can be made. First, the HMC7044 register and frequency table is not implemented. Custom firmware bypasses ZCU216 CLK104, LMK, and LMX programming; the custom Vivado flow assumes the board supplies the required RFDC clock on the DAC2 clock pins. Second, the reduced RFDC slice map using only DAC20 and DAC22 must still be validated against the physical analog outputs and clocking on the custom board.

Offline Vivado project creation for `TARGET=custom_xczu47dr` has passed through block-design creation and validation with top module `TopCustomXczu47dr` and part `xczu47dr-ffvg1517-2-i`. The custom DDR4 controller now uses a `Custom` board interface with `CONFIG.C0.DDR4_InputClockPeriod {3334}` to match the existing 300 MHz `c0_sys` port. The reference project exposes two separate 64-bit DDR4 controllers (`ddr0.xdc` and `ddr1.xdc`, with 64-bit DQ buses and `MT40A1G16RC-062E`), while this first-stage custom copy still uses the existing single-DDR4 BD path. Full DDR4 topology, memory part, data width, and pin constraints still need schematic/BOM confirmation before bitstream or hardware-readiness claims.

No custom bitstream or firmware image has been claimed as programmed, validated, or hardware-tested on the custom board.

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
