# 8-Channel DAC Expansion Progress Snapshot

Date: 2026-06-29

## Goal

Expand the `xczu47dr-rfdc` project from the earlier 4-stream mirrored DAC scheme to 8 independent physical DAC outputs. Each output should have its own DDR buffer, upload path, playback instruction/control path, GUI/CLI support, and RFDC AXIS connection.

## Current Status

The software side has been expanded and tested for 8 channels. The main RTL files have been updated for 8 independent channels, source-level checks no longer show stale slice2 mirroring or tie-off patterns, and the focused Vivado validation gates now pass. Remaining work is full Vivado project synthesis/implementation and final board-level measurement.

## Completed Work

### Software and Host Tools

- Expanded host-side DDR channel mapping to 8 buffers:
  - CH1: `0x0000`
  - CH2: `0x40000`
  - CH3: `0x80000`
  - CH4: `0xC0000`
  - CH5: `0x100000`
  - CH6: `0x140000`
  - CH7: `0x180000`
  - CH8: `0x1C0000`
- Updated waveform generation, metadata, save, and upload paths for CH1 through CH8.
- Updated CLI support so generated and uploaded waveforms can target all 8 channels.
- Updated GUI model and GUI fields/previews for 8 independent channels.
- Updated ILA capture/report tooling to default to CH1 through CH8.
- Updated software README documentation from the temporary mirrored mapping to the final 8-output mapping.

Touched software files include:

- `software/host.py`
- `software/waveform_tools.py`
- `software/send_waveform_udp.py`
- `software/waveform_gui_model.py`
- `software/waveform_gui.py`
- `software/ila_capture_report.py`
- `software/README.md`

### Software Tests

The following unittest suites were updated and passed:

- `tests/test_host_udp_waveform.py`
- `tests/test_waveform_tools.py`
- `tests/test_send_waveform_udp.py`
- `tests/test_waveform_gui.py`
- `tests/test_waveform_gui_model.py`
- `tests/test_ila_capture_report.py`

Latest combined software validation result:

```text
python3 -m unittest tests.test_host_udp_waveform tests.test_waveform_tools tests.test_send_waveform_udp tests.test_waveform_gui tests.test_waveform_gui_model tests.test_ila_capture_report
Ran 82 tests ... OK
```

### RTL Implementation Progress

The primary RTL implementation files have been expanded toward 8 independent physical channels:

- `hardware/vivado/src/waveform_system_top.v`
  - Actual instruction executor/DataMover scheduler location.
  - Expanded from 4 logical streams to 8 channel handling.
  - Keeps the existing 4-bit `instr_ch` instruction field, which can represent channels 1 through 8 without changing the instruction word format.

- `hardware/vivado/src/dac_play_ctrl.v`
  - Expanded DAC-domain playback gating/start logic for CH1 through CH8.

- `hardware/vivado/src/Top.v`
  - Expanded FIFO, gearbox, RFDC stream wiring, config CDC payload, and DAC playback control wiring for 8 independent physical outputs.

Source checks found no remaining obvious old slice2 mirroring patterns such as tied-off slice2 valid/data in the maintainable source RTL path. During validation, one stale 2-bit `dm_sel` comparison/reset residue in `waveform_system_top.v` was fixed after `dm_sel` was expanded to 3 bits for CH1 through CH8 scheduling.

Focused RTL validation completed:

```text
/tools/Xilinx/Vivado/2024.2/bin/xvlog -sv hardware/vivado/src/waveform_system_top.v hardware/vivado/src/Top.v
analyzing module Waveform_System_Top
analyzing module Waveform_Instruction_Decoder
analyzing module Waveform_Channel_State
analyzing module Waveform_Dma_Selector
analyzing module Top
```

```text
/tools/Xilinx/Vivado/2024.2/bin/xvlog -sv hardware/vivado/src/dac_play_ctrl.v tests/tb_dac_play_ctrl.sv
/tools/Xilinx/Vivado/2024.2/bin/xelab tb_dac_play_ctrl -s tb_dac_play_ctrl_sim
/tools/Xilinx/Vivado/2024.2/bin/xsim tb_dac_play_ctrl_sim -runall
PASS: dac_play_ctrl starts with auto_start after FIFO prog_empty deasserted
```

The `tests/tb_dac_play_ctrl.sv` instance was updated to include CH5 through CH8 ports, and `hardware/vivado/src/dac_play_ctrl.v` now has an explicit `` `timescale 1ns/1ps`` so Vivado simulation elaboration succeeds with the testbench.

### RFDC Mapping Decision

The target physical mapping is:

| Channel | RFDC AXIS Port | Physical Output |
|---|---|---|
| CH1 | `s00_axis` | `vout00` |
| CH2 | `s02_axis` | `vout02` |
| CH3 | `s10_axis` | `vout10` |
| CH4 | `s12_axis` | `vout12` |
| CH5 | `s20_axis` | `vout20` |
| CH6 | `s22_axis` | `vout22` |
| CH7 | `s30_axis` | `vout30` |
| CH8 | `s32_axis` | `vout32` |

The RFDC wrapper/config generator is expected to preserve all 8 AXIS interfaces:

```text
s00_axis:s02_axis:s10_axis:s12_axis:s20_axis:s22_axis:s30_axis:s32_axis
```

RFDC Chisel generation was rerun successfully:

```text
cd /home/kyu/workspace/xczu47dr-rfdc/hardware/chisel
./build.sh rfdc
RFDC Vivado configuration generated: generated/rfdc_custom_xczu47dr_config.tcl
RFDC Verilog blackbox wrapper generated: generated/RfdcCustomXczu47dr.v
Build complete
```

The generated config/wrapper were checked for the 8 AXIS interfaces, including `s20_axis`, `s22_axis`, and `s32_axis`.

## Important Findings

- The expected standalone `waveform_executor.v` file does not exist. The relevant instruction/executor/DataMover logic is in:
  - `hardware/vivado/src/waveform_system_top.v`
- The earlier root issue was generated RFDC IP tying slice2 paths to zero, for example:
  - `dac02_data_in(256'b0)`
  - `dac02_valid_in(1'b0)`
  - same pattern for `dac12`, `dac22`, and `dac32`
- Generated synth/IP output should be treated as evidence only and must not be hand-edited. The fix belongs in source/generator/top-level wiring.
- Current user measurement context:
  - `vout00` shows main peaks around `1.5G / 4.5G / 7.5G`, main about `-30 dBm`, max spur about `-50 dBm`, and little obvious clutter.
  - `vout02` appears flat/no obvious signal under the old path.

## Known Constraints and Blockers

- `rg` is unavailable in the environment; use `grep -R` for searches.
- Python LSP diagnostics are unavailable due to connection errors.
- `iverilog` and `verilator` are not installed, so local RTL simulation through those tools is unavailable.
- Vivado tools are available and should be used for RTL validation:
  - `/tools/Xilinx/Vivado/2024.2/bin/xvlog`
  - `/tools/Xilinx/Vivado/2024.2/bin/xelab`
  - `/tools/Xilinx/Vivado/2024.2/bin/xsim`
  - `/tools/Xilinx/Vivado/2024.2/bin/vivado`
- `iverilog` and `verilator` are unavailable, but focused Vivado `xvlog`/`xelab`/`xsim` gates were used instead.
- Full Vivado project synthesis/implementation has not yet been run after the 8-channel expansion. The current validation is source syntax, focused `dac_play_ctrl` simulation, Chisel RFDC generation, and software unit tests.

## Current Todo State

- Completed: Extend host/tools/CLI/GUI model and tests to 8 independent channels.
- Completed: Expand and verify RTL playback/data path from 4 mirrored streams to 8 independent streams with source grep plus focused Vivado gates.
- Completed: Run RFDC/Chisel generation and software unittest gates.
- Pending outside this checkpoint: full Vivado synthesis/implementation and board-level RF measurement.

## Recommended Next Steps

1. Run full Vivado project synthesis/implementation when ready.

```bash
cd /home/kyu/workspace/xczu47dr-rfdc
make synth
```

2. Re-run RFDC/Chisel generation if `hardware/chisel/rfdc/src/elaborate.scala` changes again:

```bash
cd /home/kyu/workspace/xczu47dr-rfdc/hardware/chisel
./build.sh rfdc
```

3. Re-run software tests after any software-side changes:

```bash
cd /home/kyu/workspace/xczu47dr-rfdc
python3 -m unittest tests.test_host_udp_waveform tests.test_waveform_tools tests.test_send_waveform_udp tests.test_waveform_gui tests.test_waveform_gui_model tests.test_ila_capture_report
```

4. Verify generated RFDC config/wrapper still exposes all 8 AXIS ports and does not tie slice2-equivalent paths to zero after any RFDC generator/IP update.

5. Perform board-level validation:
   - First test CH1 and CH2 with distinct low-amplitude DC/CW outputs and compare `vout00` vs `vout02`.
   - Then test `vout10/vout12`, `vout20/vout22`, and `vout30/vout32`.
   - Finally test all 8 outputs simultaneously.

## Files Most Relevant for Continuing

- `hardware/vivado/src/waveform_system_top.v`
- `hardware/vivado/src/dac_play_ctrl.v`
- `hardware/vivado/src/Top.v`
- `hardware/vivado/src/axis_128_to_256.v`
- `hardware/vivado/src/cfg_cdc_fifo_xpm.v`
- `hardware/chisel/rfdc/src/elaborate.scala`
- `software/host.py`
- `software/waveform_tools.py`
- `software/send_waveform_udp.py`
- `software/waveform_gui_model.py`
- `software/waveform_gui.py`
- `software/ila_capture_report.py`
- `tests/tb_dac_play_ctrl.sv`
