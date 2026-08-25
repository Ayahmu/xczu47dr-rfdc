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

Source the Xilinx tools first so `vivado` and `xsct` are on `PATH`, then use the root `Makefile` as the primary interface. The formal RFDC targets are `custom_xczu47dr_master` and `custom_xczu47dr_slave`; the default is master. `TARGET=custom_xczu47dr_bw` remains the separate DDR bandwidth-pressure design.

For the two-board synchronization build, run `make bitstream-dual`. This builds
the master and slave Vivado projects in parallel using isolated trees under
`hardware/vivado/work-dual/master` and `hardware/vivado/work-dual/slave`; the
generated bitstreams and LTX files are written as
`artifacts/custom_xczu47dr_master.*` and
`artifacts/custom_xczu47dr_slave.*`. The physical synchronization
connection for the current hardware revision is **master A <-> slave A**. Use
`make bitstream-dual-clean` to remove only the isolated dual-build trees.

The checked-in `artifacts/` directory is the single programming handoff. A fresh
clone can run `make program` immediately after sourcing Vitis; no Vivado
synthesis/implementation or Vitis workspace creation is required. Local
`make bitstream`, `make xsa`, and `make firmware` commands atomically overwrite
the same role-matched files in `artifacts/`.

```bash
# Build one formal role and its role-specific XSA/firmware workspace.
make all TARGET=custom_xczu47dr_master
make all TARGET=custom_xczu47dr_slave

# Build both 10 MHz XS17 bitstreams concurrently in isolated Vivado work trees.
make bitstream-dual

# Build only FPGA artifacts: Chisel RTL, Vivado project, synth, impl, bitstream, XSA
make hardware

# Build the standalone DDR bandwidth pressure design explicitly
TARGET=custom_xczu47dr_bw make hardware
TARGET=custom_xczu47dr_bw make firmware

# Build only firmware from the current XSA
make firmware

# Verify expected handoff artifacts exist
make artifacts

# Program the custom board over JTAG with the checked-in default artifacts
make program

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

# Build the browser control console, then launch its safe simulator mode
cd software/webui && npm ci && npm run build
cd ../..
RFSOC_WEB_SIMULATION=1 python3 -m uvicorn software.webapp.main:app --host 127.0.0.1 --port 8000
```

Open `http://127.0.0.1:8000` after the service starts. The browser console is
the normal control interface.

## Browser Control Console

The web console is a Vue 3 / TypeScript / Element Plus application served by a
headless FastAPI control service. It retains the useful operating functions of
the earlier desktop tool while separating waveform preparation from actual board control:

- Eight-channel sine / XY / readout / Z editor with IQ or Real output, per-channel delay, and final-output preview/spectrum.
- ez-Q XY / Z / readout editor with the existing fixed channel-role map.
- Dynamic registered-board inventory with login, exclusive leases, Linux USB
  discovery for Digilent JTAG serials, RFCTRL2 status, and read-only UART logs.
- Single-board waveform jobs: select one leased board, independently enable and
  configure CH1-CH8, preview, upload, ARM, issue the board-local trigger, and
  abort/mute.
- Persistent run history, immutable `.bit + .elf` releases, controlled JTAG
  deployment, programming logs, user administration, and audit records.

The current web release intentionally exposes only single-board playback. It
does not select every registered board, require a synchronization group, or
send `SYNC_EPOCH` / `START_AT`. Requests containing more than one board job are
rejected before hardware I/O. Synchronization metadata remains in the board
records for a later hardware-qualified multi-board release.

The host-side software sync step for the master/slave builds is implemented in
`software/sync_two_boards.py`: it waits for HMC7044 done, sends one
`RFCTRL2 SYNC_EPOCH` to the master, emits one pulse on the dedicated XS20 SYNC
link, then waits for DAC MTS and NCO SYSREF ready before playback. XS18 is the
Trigger output and XS19 is the Trigger input; Type-C is not a synchronization
path.

For a single-board slave Trigger loopback test, connect `XS18 -> XS19` with
an SMA/SMP cable and call `bypass_sync()` through
`software/dr47/hardware_wave_test.py`. This explicit local permission does
not claim that the board has synchronized: `sync_seen` remains false.

For normal use, build the frontend once and run the backend from the repository
root:

```bash
python3 -m pip install -r software/requirements.txt
cd software/webui
npm ci
npm run build
cd ../..

# Safe local workflow. No UDP packets are sent to a board.
RFSOC_WEB_SIMULATION=1 \
RFSOC_WEB_ADMIN_PASSWORD='replace-this-password' \
python3 -m uvicorn software.webapp.main:app --host 127.0.0.1 --port 8000

# Development UI with Vite hot reload, in a second terminal.
cd software/webui
npm run dev -- --host 127.0.0.1
```

The production frontend is served at `http://127.0.0.1:8000`; the Vite
development server normally uses `http://127.0.0.1:5173`. Log in with the
configured bootstrap administrator, register the exact JTAG/UART/network
mapping, acquire one board, and use Dry Run before enabling real control. Set
`RFSOC_WEB_SIMULATION=0` only after that board has RFCTRL2-capable firmware and
its network path has been verified. Runtime state, runs, logs, and releases are stored under
`$RFSOC_WEB_RUNTIME_DIR`, or `~/.local/state/xczu47dr-rfdc` by default.

Deployment configuration, service-account permissions, environment variables,
and systemd examples are documented in
[`software/WEB_CONSOLE_DEPLOYMENT.md`](software/WEB_CONSOLE_DEPLOYMENT.md).

The frontend uses a purpose-built operational console, not a static HTML admin
template. Vue component state, REST endpoints, and a WebSocket event stream are
used so that state changes from an ARM/start/abort request are visible to every
open browser.

## Master/Slave Sync Build And Cabling

The browser console does not currently orchestrate a multi-board experiment,
but the driver and bitstreams implement the two formal roles. Ethernet identity
is assigned at runtime by the PL network configuration protocol; it is not
encoded by role or JTAG cable serial.

| Build target | Purpose |
| --- | --- |
| `custom_xczu47dr_master` | XS20 SYNC output; local software and XS19 Trigger allowed before `sync()` |
| `custom_xczu47dr_slave` | XS20 SYNC input; external mode gates local and XS19 Trigger until SYNC or explicit `bypass_sync()` |
| `custom_xczu47dr_bw` | Standalone DDR bandwidth stress target |

```bash
make bitstream-dual
```

Board inventory is not hard-coded. The web console prepares candidate server
10G ports, sends RFCTRL2 discovery probes, and adds a board only after the PL
returns a unique `device_uid`. Current playback qualification is single-board:
`upload -> RFDC_APPLY -> ARM/PREPARED -> TRIGGER -> MUTE`. `ARM` only prepares
and prefills the PL path; `TRIGGER` is the only command that opens the output
gate.

Role-specific artifacts are named `custom_xczu47dr_master.*` and
`custom_xczu47dr_slave.*`; Vitis workspaces are likewise separate only because
their XSAs are separate. The firmware source is one shared implementation.

`make program TARGET=custom_xczu47dr_slave` programs the selected role. When multiple boards are attached, set `JTAG_CABLE_SERIAL=<serial>`, for example `JTAG_CABLE_SERIAL=210512180082 TARGET=custom_xczu47dr_slave make program`. Use UART at 115200 baud to inspect firmware output.

## Custom XCZU47DR Bring-Up Scope

The build selects the `xczu47dr-ffvg1517-2-i` part without a Vivado `board_part`, uses `hardware/vivado/xdc/custom_xczu47dr_minimal.xdc`, and selects the `TopCustomXczu47dr` wrapper. The wrapper drives the XS18 `TRIG_1` MMCX output from package ball A6 as an END-after-commit trigger/debug pulse.

The current custom scope is eight-output DAC playback on the custom XCZU47DR board using fine-NCO digital up-conversion in C2R (IQ->Real) mode. All four DAC tiles (228-231) are enabled with both physical slices (0 and 2), giving eight analog outputs `vout00/02/10/12/20/22/30/32`. The eight executor channels map one-to-one to the eight logical playback streams: CH1->`vout00`, CH2->`vout02`, CH3->`vout10`, CH4->`vout12`, CH5->`vout20`, CH6->`vout22`, CH7->`vout30`, CH8->`vout32`. CH1-CH4 are XY, CH5-CH6 are Z, and CH7-CH8 are readout channels. The RFDC IP is in `Multi x2(all)` C2R mode and the normal wrapper connects the eight active logical 256-bit RFDC AXIS streams to `s00/s02/s10/s12/s20/s22/s30/s32`; generated companion ports `s01/s03/s11/s13/s21/s23/s31/s33` are tied off by the wrapper for this configuration. Within every logical 256-bit RFDC word, software stores little-endian int16 lanes as `I0,Q0,I1,Q1,...,I7,Q7`.

Host upload now defaults to the `interleaved_512b` DDR layout. Each 512-bit DDR beat contains eight 64-bit lanes: lane0 is CH1 sample group `N`, lane1 is CH2, through lane7 as CH8. Four consecutive DDR beats are packed in hardware into one 256-bit RFDC beat per channel. The DataMover reads one continuous DDR region instead of switching among per-channel address ranges. The old `tiled` and `contiguous` layouts remain in software for debug/fallback, but the normal RFDC Top uses the interleaved executor.

Each DAC is targeted at `Fs = 6.4 GS/s` with `16x` interpolation, so the RFDC input complex I/Q rate is `400 MS/s` and the PL/AXIS fabric clock is `50 MHz` (`8` complex samples per 256-bit RFDC beat). DAC2 (tile 230) owns the PLL from the HMC7044 128 MHz refclk and distributes to all tiles. Every active DAC slice is configured for fine-NCO C2R up-conversion (`I/Q->Real`, fine mixer). XY/readout use the RFDC NCO for the RF carrier; software `detune_hz` is only a small baseband offset. In this baseline, CH1-CH4 default XY at 4.5 GHz maps to Zone2 with NCO `-1.9 GHz`; CH5-CH6 default Z channels use `NCO = 0` with DC coupling on tile 230; CH7-CH8 default readout targets are 5.8/6.2 GHz and map to Zone2 with NCO `-0.6/-0.2 GHz`.

Runtime NCO, NCO phase, Nyquist zone, and DAC VOP configuration uses a pure-PL closed loop: FastAPI sends structured `RFCTRL2 RFDC_APPLY` UDP packets, the PL validates all selected channels, performs 16-bit RFDC AXI-Lite writes, reads the critical registers back, and returns a structured `RFRESP2` UDP response. DDR mailbox polling, PS runtime register writes, and UART `RFDC_APPLY` confirmation are not part of this path. The PS only starts RFDC tiles, PLLs, and calibration during boot; UART remains an optional diagnostic console.

The current mainline HMC7044 plan accepts a 10 MHz XS17 reference and generates the 128 MHz DAC reference used by the 6.4 GS/s, 16x RFDC configuration. Firmware waits only for HMC7044 programming to finish, then initializes RFDC/MTS/NCO without waiting for XS20. The RTL drives `RESET_H7044_H_0` low as the released state for the active-high reset net; verify that polarity against the schematic during hardware bring-up. The custom firmware no longer initializes PS Ethernet or lwIP.

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

This removes Vivado work trees, reports, the old ignored `hardware/vivado/output/`
directory, and the Vitis workspace. It does not delete the checked-in
`artifacts/` programming handoff. Recreate generated state with `make hardware`
and `make firmware`.
