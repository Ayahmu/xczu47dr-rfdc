# Hardware Design

This directory contains the Chisel sources, Vivado design, constraints, and hardware build scripts for the custom XCZU47DR RFDC board.

## Supported RFDC Designs

The production RFDC designs are intentionally limited to two bitstreams:

| Target | XS20 direction | Local playback policy |
|---|---|---|
| `custom_xczu47dr_master` | SYNC output | Software and XS19 triggers are always allowed. `sync()` emits a synchronization pulse. |
| `custom_xczu47dr_slave` | SYNC input | External mode requires a real XS20 synchronization event. The driver can explicitly call `bypass_sync()` for local bring-up. |

The normal clock plan is XS17 = **10 MHz** external reference and HMC7044 DAC reference = **128 MHz**. The board-to-board synchronization connection is **master A <-> slave A**. XS18 is the trigger output and XS19 is the trigger input.

`custom_xczu47dr_bw` is a separate DDR bandwidth test target, not an RFDC playback personality. There is no production `selftest` RFDC target.

## Build Prerequisites

- Vivado 2024.2, with `settings64.sh` sourced.
- Java and Mill if Chisel sources need regeneration.
- Sufficient local disk space for two concurrent Vivado projects.

```bash
source /tools/Xilinx/Vivado/2024.2/settings64.sh
source /tools/Xilinx/Vitis/2024.2/settings64.sh
```

## Normal Build Workflow

Run commands from the repository root.

```bash
# Build one role and its XSA.
make hardware TARGET=custom_xczu47dr_master
make hardware TARGET=custom_xczu47dr_slave

# Build both FPGA bitstreams concurrently.
make bitstream-dual

# Build an ELF against the selected role-specific XSA.
make firmware TARGET=custom_xczu47dr_slave
```

`make bitstream-dual` first performs the shared Chisel generation, then runs two Vivado builds concurrently. Their mutable state is isolated:

```text
hardware/vivado/work-dual/master/
hardware/vivado/work-dual/slave/
hardware/vivado/reports-dual/master/
hardware/vivado/reports-dual/slave/
```

The resulting checked-in handoff files are:

```text
artifacts/custom_xczu47dr_master.bit
artifacts/custom_xczu47dr_master.ltx
artifacts/custom_xczu47dr_master.xsa
artifacts/custom_xczu47dr_slave.bit
artifacts/custom_xczu47dr_slave.ltx
artifacts/custom_xczu47dr_slave.xsa
```

The build prints each bitstream's path, byte size, and SHA256. `make bitstream-dual-clean` removes only the dual-build projects and reports; it does not remove artifacts. `make clean` removes all ignored Vivado work/report trees, including historical `work-10mhz`, `work-isolated-sync`, `work-selftest`, and `reports-*` directories, as well as Chisel/Mill and Vitis generated state. It preserves artifacts. Use `make artifacts-clean TARGET=...` only when explicitly removing a role's programming files.

## Firmware and Programming

The firmware source is shared by master and slave. Build it with the XSA that matches the bitstream role being programmed. Firmware waits only for the HMC7044 PL sequencer, then initializes RFDC, DAC MTS, and NCO SYSREF; it does not wait for XS20 synchronization.

```bash
JTAG_CABLE_SERIAL=<serial> TARGET=custom_xczu47dr_slave make program
```

Do not program a master ELF/XSA with a slave bitstream, or vice versa. A clone
can program directly with `make program`; the command does not create a Vitis
workspace or rebuild firmware.

## Driver-Level Synchronization Policy

The FPGA role is fixed at synthesis time. The driver cannot turn a slave bitstream into a master or change XS20's electrical direction.

For a slave with no XS20 source, `bypass_sync()` is deliberately explicit:

```python
from dr47 import Dr47Device

with Dr47Device(ip="169.254.32.1", udp_interface="enp225s0f1") as device:
    device.bypass_sync()            # Allows local software/XS19 triggers.
    # Upload, arm, then issue a software trigger or feed XS19.
    device.require_external_sync()  # Closes the gate again.
```

`sync_seen` always means a real XS20 event. Bypass does not manufacture a synchronization event. A mode change is rejected while playback is prepared, armed, or running. The legacy `self_test` driver string is only a deprecated compatibility alias for `bypass`; new code must use `bypass`.

## Verification

Useful static checks:

```bash
make -n bitstream-master bitstream-slave bitstream-dual xsa-master xsa-slave
PYTHONPATH=software python3 -m unittest tests.test_dr47_driver tests.test_rtl_sim -q
git diff --check
```

For the one-board slave setup: XS17 = 10 MHz, XS20 unconnected, and XS18 physically connected to XS19, run:

```bash
PYTHONPATH=software python -m dr47.hardware_sync_mode_test
```

For a master role test, program the master artifacts and run:

```bash
PYTHONPATH=software python -m dr47.hardware_master_local_test
```

These tests validate control and trigger state, not analog RF quality. RF frequency, amplitude, and spectral claims require oscilloscope or spectrum analyzer evidence.
