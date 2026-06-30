# XCZU47DR RFDC

FPGA, bare-metal firmware, and host-control project for custom XCZU47DR RFDC waveform playback.

## Project Layout

```text
xczu47dr-rfdc/
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

Source the Xilinx tools first so `vivado` and `xsct` are on `PATH`, then use the root `Makefile` as the primary interface. The only supported target is `custom_xczu47dr`, and it is the default.

```bash
# Full custom XCZU47DR hardware and firmware build
make all

# Build only FPGA artifacts: Chisel RTL, Vivado project, synth, impl, bitstream, XSA
make hardware

# Build only firmware from the current XSA
make firmware

# Verify expected handoff artifacts exist
make artifacts

# Program the custom board over JTAG with the default bitstream and ELF
make run

# Or program with explicit artifacts
make run BIT=/path/to/top.bit ELF=/path/to/app.elf PSU_INIT=/path/to/psu_init.tcl

# Preview firmware create and program paths without XSCT or JTAG actions
cd firmware
DRY_RUN=1 ./build.sh create
DRY_RUN=1 ./build.sh program

# Offline host validation without board access
make host-dry-run

# Launch the local waveform GUI
python3 software/waveform_gui.py
```

Default handoff artifacts:

- Bitstream: `hardware/vivado/output/custom_xczu47dr_rfdc.bit`
- Debug probes: `hardware/vivado/output/custom_xczu47dr_rfdc.ltx`
- Hardware handoff: `hardware/vivado/output/custom_xczu47dr_rfdc.xsa`
- Firmware ELF: `firmware/workspace/custom_xczu47dr/rfdc_app/Debug/rfdc_app.elf`
- PS init script: `firmware/workspace/custom_xczu47dr/hw_platform/hw/psu_init.tcl`

`make run` programs the custom board over JTAG with the `.bit`, runs PS initialization from `psu_init.tcl`, downloads the ELF to `Cortex-A53 #0`, and starts execution. Use UART at 115200 baud to inspect firmware output. Verify the HMC7044 sequencer done bit, RFDC DAC tile startup messages, and per-channel analog output before treating a bitstream as hardware-qualified.

## Custom XCZU47DR Bring-Up Scope

The build selects the `xczu47dr-ffvg1517-2-i` part without a Vivado `board_part`, uses `hardware/vivado/xdc/custom_xczu47dr_minimal.xdc`, and selects the `TopCustomXczu47dr` wrapper. The wrapper drives the XS18 `TRIG_1` MMCX output from package ball A6 as an END-after-commit trigger/debug pulse.

The current custom scope is eight-output DAC playback on the custom XCZU47DR board using fine-NCO digital up-conversion in C2R (IQ->Real) mode. All four DAC tiles (228-231) are enabled with both slices (0 and 2), giving eight analog outputs `vout00/02/10/12/20/22/30/32`. The eight executor channels map one-to-one to the eight active RFDC slice AXIS streams: CH1->`s00_axis`, CH2->`s02_axis`, CH3->`s10_axis`, CH4->`s12_axis`, CH5->`s20_axis`, CH6->`s22_axis`, CH7->`s30_axis`, CH8->`s32_axis`. The DataMover reads DDR through a 512-bit AXI-MM port, keeps multiple 4 KiB MM2S commands outstanding, and outputs native 256-bit RFDC beats through per-channel 256-bit async FIFOs into the physical DAC slices; the old 128-to-256 gearbox has been removed. Within every 256-bit RFDC word, software stores little-endian int16 lanes as `I0,Q0,I1,Q1,...,I7,Q7`. Per-channel DDR buffers use 32B-aligned 256 KiB default slots (`0x0`, `0x40000`, ..., `0x1C0000`) so longer CW uploads cannot overlap. PCIe, QSFP, Type-C, Aurora, ADC capture, LEDs, and unrelated board interfaces remain outside this bring-up scope unless requested later.

Each DAC runs at `Fs = 6.0 GS/s` with `8x` interpolation, so the PL/AXIS fabric clock is `Fs / interp / 8 = 93.75 MHz`. DAC2 (tile 230) owns the PLL from the 125 MHz HMC7044 refclk (`Clock_Dist=2`) and distributes to all tiles (`Clock_Source=6`). Every DAC slice is configured for fine-NCO C2R up-conversion (`DAC_Mixer_Mode=1`, `DAC_Mixer_Type=2` / `Fine`, `DAC_Data_Type=1` / `I/Q`) in Nyquist Zone 2. For single-frequency CW the host streams a constant DC complex baseband (constant I, Q=0); the C2R fine NCO then translates the tone entirely by the NCO frequency, producing one clean tone per output. With `Fs = 6.0 GS/s` a baseband NCO of `-1.5 GHz` lands the Zone 2 image at `6.0 - 1.5 = 4.5 GHz`. The firmware sets the NCO once at startup via `Configure_Custom_DAC_NCO()` (default `-1.5 GHz`) and the wrapper allows retuning across the 4-5 GHz band at runtime without rebuilding the bitstream.

The custom PL includes an HMC7044 sequencer and the firmware waits for its done bit before RFDC startup. The RTL currently drives `RESET_H7044_H_0` low as the released state for the active-high reset net; verify that polarity against the schematic during hardware bring-up. The host DC-CW path now writes explicit interleaved `I=C,Q=0` samples; tone frequency is set by the firmware NCO, not by the host sample rate. The custom firmware no longer initializes PS Ethernet or lwIP.

Vivado project creation and synthesis have passed for `TARGET=custom_xczu47dr` with top module `TopCustomXczu47dr` and part `xczu47dr-ffvg1517-2-i`; implementation/bitstream generation is the final gate for the current 256-bit native playback revision. The custom DDR4 controller uses a `Custom` board interface with `CONFIG.C0.DDR4_InputClockPeriod {3334}` to match the existing 300 MHz `c0_sys` port. The reference project exposes two separate 64-bit DDR4 controllers, while this bring-up flow still uses the existing single-DDR4 BD path. Full DDR4 topology, memory part, data width, and pin constraints still need schematic/BOM confirmation before production hardware-readiness claims.

Generated custom bitstream, XSA, and firmware ELF artifacts exist, but hardware qualification still requires JTAG programming, UART RFDC/HMC7044 status review, ILA checks on the 256-bit `s00/s02/s10/s12/s20/s22/s30/s32_axis` streams, and per-output measurements on `vout00/02/10/12/20/22/30/32`.

## Requirements

- Vivado 2024.2
- Vitis/XSCT 2024.2
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
