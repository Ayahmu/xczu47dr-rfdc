# Vivado RFDC Build

This directory holds the Vivado sources for the custom XCZU47DR RFDC design. Design inputs are in `src/`, `xdc/`, `bd/`, `ip/`, and `scripts/`. Vivado projects, generated IP products, `.Xil`, and reports are generated locally and ignored by Git; final programming artifacts are written to the checked-in root `artifacts/` directory.

## Production Targets

| Make target | Fixed role | XS20 | Trigger policy |
|---|---|---|---|
| `custom_xczu47dr_master` | master | output | Local software and XS19 triggers are always accepted; driver `sync()` emits XS20 synchronization. |
| `custom_xczu47dr_slave` | slave | input | In `external` mode, playback requires a real XS20 event. In explicit driver `bypass` mode, local software and XS19 triggers are allowed. |

The role is a synthesis-time definition (`CUSTOM_XCZU47DR_MASTER` or `CUSTOM_XCZU47DR_SLAVE`), not a run-time selection. A slave cannot be changed into a master by software. `sync_seen` reports only an actual XS20 event; it is never set merely because bypass is enabled.

The mainline clock plan uses a 10 MHz XS17 reference, HMC7044 programming in the PL sequencer, and a 128 MHz DAC reference. Connect synchronization as **master A <-> slave A**. XS18 is trigger output and XS19 is trigger input.

`custom_xczu47dr_bw` remains an independent bandwidth-pressure target. There is no production `custom_xczu47dr_selftest` target.

## Build

Source the required toolchain, then run commands from the repository root:

```bash
source /tools/Xilinx/Vivado/2024.2/settings64.sh
source /tools/Xilinx/Vitis/2024.2/settings64.sh

make bitstream TARGET=custom_xczu47dr_master
make bitstream TARGET=custom_xczu47dr_slave
make bitstream-dual
```

For a complete single-role build, including the role-specific XSA:

```bash
make hardware TARGET=custom_xczu47dr_slave
```

The common Make variables may be overridden for an isolated build:

```bash
make bitstream TARGET=custom_xczu47dr_master \
  VIVADO_WORK_DIR=/path/to/work \
  VIVADO_OUTPUT_DIR=/path/to/output
```

## Dual Build Isolation

`make bitstream-dual` runs two GNU Make children with `-j2`. Each owns all mutable Vivado state, so concurrent builds never share a `.xpr`, `.runs`, `.Xil`, cache, generated sources, or report directory:

```text
work-dual/master/      reports-dual/master/
work-dual/slave/       reports-dual/slave/
```

Both publish role-specific outputs after bitstream generation:

```text
../../artifacts/custom_xczu47dr_master.bit
../../artifacts/custom_xczu47dr_master.ltx
../../artifacts/custom_xczu47dr_master.xsa
../../artifacts/custom_xczu47dr_slave.bit
../../artifacts/custom_xczu47dr_slave.ltx
../../artifacts/custom_xczu47dr_slave.xsa
```

The dual command reports the size and SHA256 of each `.bit`. Remove only its isolated projects with:

```bash
make bitstream-dual-clean
```

## Build Stages

For diagnosis, the individual stages are available and use the selected `TARGET`, `VIVADO_WORK_DIR`, `VIVADO_OUTPUT_DIR`, and `VIVADO_REPORT_DIR`:

```bash
make vivado-project TARGET=custom_xczu47dr_slave
make preflight TARGET=custom_xczu47dr_slave
make synth TARGET=custom_xczu47dr_slave
make impl TARGET=custom_xczu47dr_slave
make bitstream TARGET=custom_xczu47dr_slave
make xsa TARGET=custom_xczu47dr_slave
```

`make xsa-master` and `make xsa-slave` export from existing corresponding dual-build projects.

## Firmware Pairing and Board Verification

Build one shared firmware source tree against the XSA matching the selected role. The firmware waits for the HMC7044 PL sequencer but intentionally does not wait for XS20 before initializing RFDC, DAC MTS, and NCO SYSREF.

For the standalone slave test, use XS17 = 10 MHz, leave XS20 unconnected, and connect XS18 to XS19. Program slave bitstream and matching ELF, then run:

```bash
PYTHONPATH=software python -m dr47.hardware_sync_mode_test
```

The test verifies that external mode rejects trigger-gated playback, explicit `bypass_sync()` enables software and XS19 triggers, and restoring external mode closes the gate. It proves digital control state only; analog RF output requires independent instrument measurement.

## Reports

Within a chosen project directory, report paths follow Vivado's normal form:

```text
<work>/<project>.runs/synth_1/reports/
<work>/<project>.runs/impl_1/reports/
```

Check the implementation timing summary for WNS/TNS and WHS/THS. Existing methodology DRC warnings must be evaluated by their rule and affected cells; they are not automatically timing failures.
