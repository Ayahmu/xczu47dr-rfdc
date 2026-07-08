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

Source the Xilinx tools first so `vivado` and `xsct` are on `PATH`, then use the root `Makefile` as the primary interface. The default target is `custom_xczu47dr`, which builds the normal eight-output RFDC playback path. Use `TARGET=custom_xczu47dr_bw` only when you explicitly want the standalone DDR bandwidth pressure design.

```bash
# Full normal RFDC playback hardware and firmware build
make all

# Build only FPGA artifacts: Chisel RTL, Vivado project, synth, impl, bitstream, XSA
make hardware

# Build the standalone DDR bandwidth pressure design explicitly
TARGET=custom_xczu47dr_bw make hardware
TARGET=custom_xczu47dr_bw make firmware

# Build only firmware from the current XSA
make firmware

# Verify expected handoff artifacts exist
make artifacts

# Program the custom board over JTAG with the default bitstream and ELF
make run

# Select one board when multiple JTAG cables are connected
JTAG_CABLE_SERIAL=210512180082 make program

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

Default normal RFDC playback handoff artifacts:

- Bitstream: `hardware/vivado/output/custom_xczu47dr_rfdc.bit`
- Debug probes: `hardware/vivado/output/custom_xczu47dr_rfdc.ltx`
- Hardware handoff: `hardware/vivado/output/custom_xczu47dr_rfdc.xsa`
- Firmware ELF: `firmware/workspace/custom_xczu47dr/rfdc_app/Debug/rfdc_app.elf`
- PS init script: `firmware/workspace/custom_xczu47dr/hw_platform/hw/psu_init.tcl`

`make run` and `make program` program the custom board over JTAG with the `.bit`, run PS initialization from `psu_init.tcl`, download the ELF to `Cortex-A53 #0`, and start execution. When multiple boards are attached, set `JTAG_CABLE_SERIAL=<serial>` to select the cable, for example `JTAG_CABLE_SERIAL=210512180082 make program`; the normal `TARGET=custom_xczu47dr` path defaults to serial `210512180081`, while the bandwidth target should be selected explicitly when more than one cable is connected. Use UART at 115200 baud to inspect firmware output.

## Custom XCZU47DR Bring-Up Scope

The build selects the `xczu47dr-ffvg1517-2-i` part without a Vivado `board_part`, uses `hardware/vivado/xdc/custom_xczu47dr_minimal.xdc`, and selects the `TopCustomXczu47dr` wrapper. The wrapper drives the XS18 `TRIG_1` MMCX output from package ball A6 as an END-after-commit trigger/debug pulse.

The current custom scope is eight-output DAC playback on the custom XCZU47DR board using fine-NCO digital up-conversion in C2R (IQ->Real) mode. All four DAC tiles (228-231) are enabled with both physical slices (0 and 2), giving eight analog outputs `vout00/02/10/12/20/22/30/32`. The eight executor channels map one-to-one to the eight logical playback streams: CH1->`vout00`, CH2->`vout02`, CH3->`vout10`, CH4->`vout12`, CH5->`vout20`, CH6->`vout22`, CH7->`vout30`, CH8->`vout32`. CH1-CH4 are XY, CH5-CH6 are Z, and CH7-CH8 are readout channels. The RFDC IP is in `Multi x2(all)` C2R mode and the normal wrapper connects the eight active logical 256-bit RFDC AXIS streams to `s00/s02/s10/s12/s20/s22/s30/s32`; generated companion ports `s01/s03/s11/s13/s21/s23/s31/s33` are tied off by the wrapper for this configuration. Within every logical 256-bit RFDC word, software stores little-endian int16 lanes as `I0,Q0,I1,Q1,...,I7,Q7`.

Host upload now defaults to the `interleaved_512b` DDR layout. Each 512-bit DDR beat contains eight 64-bit lanes: lane0 is CH1 sample group `N`, lane1 is CH2, through lane7 as CH8. Four consecutive DDR beats are packed in hardware into one 256-bit RFDC beat per channel. The DataMover reads one continuous DDR region instead of switching among per-channel address ranges. The old `tiled` and `contiguous` layouts remain in software for debug/fallback, but the normal RFDC Top uses the interleaved executor.

Each DAC is targeted at `Fs = 6.4 GS/s` with `16x` interpolation, so the RFDC input complex I/Q rate is `400 MS/s` and the PL/AXIS fabric clock is `50 MHz` (`8` complex samples per 256-bit RFDC beat). DAC2 (tile 230) owns the PLL from the HMC7044 128 MHz refclk and distributes to all tiles. Every active DAC slice is configured for fine-NCO C2R up-conversion (`I/Q->Real`, fine mixer). XY/readout use the RFDC NCO for the RF carrier; software `detune_hz` is only a small baseband offset. In this baseline, CH1-CH4 default XY at 4.5 GHz maps to Zone2 with NCO `-1.9 GHz`; CH5-CH6 default Z channels use `NCO = 0` with DC coupling on tile 230; CH7-CH8 default readout targets are 5.8/6.2 GHz and map to Zone2 with NCO `-0.6/-0.2 GHz`. The GUI writes these per-channel NCO and Nyquist settings through the DDR mailbox before issuing PLAY instructions.

The custom PL includes an HMC7044 sequencer and the firmware waits for its done bit before RFDC startup. The RTL currently drives `RESET_H7044_H_0` low as the released state for the active-high reset net; verify that polarity against the schematic during hardware bring-up. The host DC-CW path now writes explicit interleaved `I=C,Q=0` samples; tone frequency is set by the firmware NCO, not by the host sample rate. The custom firmware no longer initializes PS Ethernet or lwIP.

Vivado project creation and synthesis have passed for `TARGET=custom_xczu47dr` with top module `TopCustomXczu47dr` and part `xczu47dr-ffvg1517-2-i`; implementation/bitstream generation is the final gate for the current 256-bit native playback revision. The custom DDR4 controller uses a `Custom` board interface with `CONFIG.C0.DDR4_InputClockPeriod {3334}` to match the existing 300 MHz `c0_sys` port. The reference project exposes two separate 64-bit DDR4 controllers, while this bring-up flow still uses the existing single-DDR4 BD path. Full DDR4 topology, memory part, data width, and pin constraints still need schematic/BOM confirmation before production hardware-readiness claims.

Generated custom bitstream, XSA, and firmware ELF artifacts exist, but hardware qualification still requires JTAG programming, UART RFDC/HMC7044 status review, ILA checks on the 512-bit DataMover stream, 512b-to-8ch packer outputs, 256-bit RFDC channel streams, and per-output measurements on `vout00/02/10/12/20/22/30/32`.

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
