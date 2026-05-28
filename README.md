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

Source the Xilinx tools first so `vivado` and `xsct` are on `PATH`, then use the root `Makefile` as the primary interface. The default target is `TARGET=zcu216`. Use `TARGET=custom_xczu47dr` for the custom XCZU47DR four-DAC bring-up flow.

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

# Offline host validation without board access
make host-dry-run

# Launch the local waveform GUI
python3 software/waveform_gui.py
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

`make run` programs the selected target over JTAG with the `.bit`, runs PS initialization from `psu_init.tcl`, downloads the ELF to `Cortex-A53 #0`, and starts execution. Use UART at 115200 baud to inspect firmware output. For `TARGET=custom_xczu47dr`, verify the HMC7044 sequencer done bit, RFDC DAC tile startup messages, and per-channel analog output before treating a bitstream as hardware-qualified.

## Custom XCZU47DR Bring-Up Scope

`TARGET=custom_xczu47dr` selects the `xczu47dr-ffvg1517-2-i` part without a Vivado `board_part`, uses `hardware/vivado/xdc/custom_xczu47dr_minimal.xdc`, and selects the `TopCustomXczu47dr` wrapper. The wrapper drives the XS18 `TRIG_1` MMCX output from package ball A6 as an END-after-commit trigger/debug pulse.

The current custom scope is four-channel DAC playback on the custom XCZU47DR board. CH1/CH2/CH3/CH4 map to RFDC DAC20/DAC22/DAC30/DAC32 and DDR offsets `0x0`/`0x1000`/`0x2000`/`0x3000`. PCIe, QSFP, Type-C, Aurora, ADC capture, LEDs, and unrelated board interfaces remain outside this bring-up scope unless requested later.

The user-provided reference project `/home/kyu/workspace/fpga_rfsoc_zjdx_20260503_jiaofu` is also built for `xczu47dr-ffvg1517-2-i`. Its generated RFDC XCI uses DAC tile 2 slices 20/22 with `DAC2_Sampling_Rate=1`, `DAC2_Refclk_Freq=125.000`, and interpolation mode `1`. The custom target runs DAC2/DAC3 at 4.8 GS/s with 4x interpolation, uses a 1.2 GS/s host/PL stream, sets the HMC7044 DAC refclk outputs to 120 MHz, and configures DAC3 to use the DAC2/DAC230 clock source rather than its own PLL.

The custom PL includes an HMC7044 sequencer and the firmware waits for its done bit before RFDC startup. The RTL currently drives `RESET_H7044_H_0` low as the released state for the active-high reset net; verify that polarity against the schematic during hardware bring-up. The host waveform default sample rate is 1.2 GS/s to match the custom 4.8 GS/s RFDC configuration. The custom firmware no longer initializes PS Ethernet or lwIP.

Vivado project creation, synthesis, implementation, bitstream generation, and XSA export have passed for `TARGET=custom_xczu47dr` with top module `TopCustomXczu47dr` and part `xczu47dr-ffvg1517-2-i`. The custom DDR4 controller uses a `Custom` board interface with `CONFIG.C0.DDR4_InputClockPeriod {3334}` to match the existing 300 MHz `c0_sys` port. The reference project exposes two separate 64-bit DDR4 controllers, while this bring-up flow still uses the existing single-DDR4 BD path. Full DDR4 topology, memory part, data width, and pin constraints still need schematic/BOM confirmation before production hardware-readiness claims.

Generated custom bitstream, XSA, and firmware ELF artifacts exist, but hardware qualification still requires JTAG programming, UART RFDC/HMC7044 status review, ILA checks on `S_AXIS_20/22/30/32`, and per-output measurements on `vout20/vout22/vout30/vout32`.

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
