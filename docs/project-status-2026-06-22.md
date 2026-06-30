# Project Status - 2026-06-22

## 1. Current Objective

The project is now centered on the custom XCZU47DR RFDC board. The previous evaluation-board target path has been removed from the tracked source tree, and the root workflow defaults to the custom board target.

The current technical direction is eight-output DAC playback on the custom RFSoC board. The hardware path uses four DAC tiles with two enabled slices per tile. The host side exposes eight logical channels, while the executor and AXIS path still operate per tile.

## 2. Target Cleanup Status

The old target cleanup has already landed in history as commit `db5af54`. That commit changed build entry points, Vivado target configuration, firmware board selection, documentation, and removed old RF clock helper sources.

Current tracked-source verification shows no remaining matches for the old target keywords or old board constraint file name in the searched project paths. The root `Makefile` now has:

```make
TARGET ?= custom_xczu47dr
ALLOWED_TARGETS := custom_xczu47dr
```

This means passing any unsupported target now fails at make-time instead of silently selecting an old path.

## 3. Build Flow Status

The root workflow is:

```bash
make all
make hardware
make firmware
make run
```

No target override is required for the normal custom board flow. The README now states that the only supported target is `custom_xczu47dr`, and lists custom-board output artifacts:

- `hardware/vivado/output/custom_xczu47dr_rfdc.bit`
- `hardware/vivado/output/custom_xczu47dr_rfdc.ltx`
- `hardware/vivado/output/custom_xczu47dr_rfdc.xsa`
- `firmware/workspace/custom_xczu47dr/rfdc_app/Debug/rfdc_app.elf`
- `firmware/workspace/custom_xczu47dr/hw_platform/hw/psu_init.tcl`

Vivado project creation was previously run successfully for the custom target and produced:

```text
hardware/vivado/work/custom_xczu47dr_rfdc.xpr
```

The earlier verification found `INFO: Project creation complete` and the generated project path in the Vivado output.

## 4. Hardware Architecture Status

The top-level hardware target is `TopCustomXczu47dr`, wrapping `Top`. The custom board path selects part `xczu47dr-ffvg1517-2-i` without a Vivado board part and uses:

```text
hardware/vivado/xdc/custom_xczu47dr_minimal.xdc
```

The design currently supports eight analog DAC outputs:

```text
vout00, vout02, vout10, vout12, vout20, vout22, vout30, vout32
```

Historical note: this 2026-06-22 status described the older four-tile packing assumption. The current design uses eight executor channels mapped one-to-one to `s00/s02/s10/s12/s20/s22/s30/s32`; each 256-bit AXIS word carries one physical DAC slice in interleaved C2R lane order `I0,Q0,I1,Q1,...,I7,Q7`.

The custom board clock policy uses an HMC7044 sequencer in PL. Firmware waits for the HMC7044 done bit before RFDC startup. The reset polarity and final clock-chip behavior still need hardware-side confirmation against the schematic and board measurements.

## 5. Firmware Status

The firmware now targets only the custom board define. The old CLK104 initialization path and related helper sources were removed in the prior cleanup commit.

Current firmware work changes the NCO configuration model from one shared NCO value to per-output RF targets. In `firmware/src/main.c`, the active diff includes:

- `CUSTOM_DAC_FS_GHZ = 6.0`
- `CUSTOM_DAC_RF_TARGET_GHZ[8]`
- `Configure_Custom_DAC_NCO_PerBlock(...)`

The default target RF output is currently 4.5 GHz on all eight DAC outputs, which maps to a 1.5 GHz fine NCO. Each entry maps to one physical output in channel order. The firmware accepts only the supported 3.5-5.5 GHz bring-up band and computes:

```text
f_nco = Fs - RF
```

for Nyquist Zone 2 operation.

## 6. Host Software Status

Current uncommitted host-side work in `software/host.py` expands the user-facing model from four tile channels to eight logical DAC channels.

The intended mapping is:

```text
CH1 -> vout00
CH2 -> vout02
CH3 -> vout10
CH4 -> vout12
CH5 -> vout20
CH6 -> vout22
CH7 -> vout30
CH8 -> vout32
```

Historical note: an earlier revision used a 128-to-256 gearbox to concatenate two consecutive DDR beats for one RFDC slice stream. The current 256-bit native path removes that gearbox: DataMover, async FIFO, and RFDC AXIS data are all 256-bit.

The CLI now supports eight logical channels and an optional per-channel amplitude list:

```bash
python3 software/host.py --channels 1,2,3,4,5,6,7,8 --amps 0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5
```

`software/waveform_tools.py` metadata now records the 6.0 GS/s DAC sample rate, 93.75 MHz AXIS rate, default 1.5 GHz NCO, default 4.5 GHz RF output, and the eight physical DAC port names.

This work is not yet committed.

## 7. Current Working Tree

At the time of this status snapshot, the uncommitted tracked changes are:

```text
firmware/src/main.c
software/host.py
```

There is also an untracked `docs/` tree containing project planning/status material.

The current uncommitted diff is not the old target cleanup. It is mainly the eight-channel independent amplitude and per-port RF/NCO configuration work plus documentation and test updates.

## 8. Validation Already Performed

The following checks have passed in this session or immediately prior work:

- tracked-source search for old target strings returned no matches
- root `Makefile` confirms `custom_xczu47dr` is the only allowed target
- README describes only the custom target workflow
- shell syntax checks passed for build scripts
- firmware dry-run create path resolves to the custom workspace, custom XSA, and `BOARD_CUSTOM_XCZU47DR`
- Vivado project creation previously reached `Project creation complete` for `custom_xczu47dr_rfdc.xpr`

The C language server cannot fully validate bare-metal firmware outside the generated Vitis BSP because headers such as `xparameters.h` and `xtime_l.h` are generated by the platform workflow.

## 9. Open Risks

1. Hardware qualification is still pending. The bitstream/project can be generated, but analog output correctness requires board programming, UART log review, ILA checks, and oscilloscope/spectrum measurements.
2. The HMC7044 reset and done-bit behavior must be verified on real hardware.
3. The obsolete tile-half packing risk has been replaced by the current eight-stream contract: each channel buffer must already be ordered as `I0,Q0,I1,Q1,...,I7,Q7` before UDP upload, because the gearbox does not reorder samples. This should be verified with ILA and per-output amplitude/phase tests.
4. Per-output RF/NCO configuration is currently compile-time firmware data. Runtime retuning would need a command/control path if required later.
5. The single-DDR4 path remains the current bring-up design. Full production memory topology still depends on schematic/BOM confirmation.

## 10. Recommended Next Steps

1. Run `python3 software/host.py --dry-run --channels 1,2,3,4,5,6,7,8 --amps ...` to verify host artifact generation for independent channel amplitudes.
2. Rebuild firmware and confirm the Vitis build accepts `Configure_Custom_DAC_NCO_PerBlock` with the generated BSP.
3. Program the board with `make run` and inspect UART logs for HMC7044 done, RFDC startup, Nyquist zone, output current, and per-channel NCO messages.
4. Use ILA or analog measurement to confirm each logical channel maps to the expected physical output.
5. Commit the current eight-channel/NCO work once host dry-run and firmware build are verified.
