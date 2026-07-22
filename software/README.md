# Software - RFSoC Waveform Sender

## Browser Console

Use the browser console as the primary operating interface. It replaces the
desktop Tkinter workflow with a Vue 3 frontend and a headless FastAPI service;
the Python code remains a backend transport and waveform-generation layer, not
a desktop application.

```bash
python3 -m pip install -r software/requirements.txt
cd software/webui
npm ci
npm run build
cd ../..

# Safe simulation: generate artifacts, exercise ARM/start/abort, no board I/O.
RFSOC_WEB_SIMULATION=1 \
RFSOC_WEB_ADMIN_PASSWORD='replace-this-password' \
python3 -m uvicorn software.webapp.main:app --host 127.0.0.1 --port 8000
```

Open `http://127.0.0.1:8000`. The console provides manual eight-channel and
ez-Q waveform editors, waveform/FFT previews, dynamic registered-board
selection, exclusive leases, dry-run, run history, WebSocket events, ARM,
board-local trigger, and abort/mute controls. The selected board has its own
complete CH1-CH8 configuration; disabled channels are excluded from the ARM
mask. Build the frontend before starting the backend; FastAPI serves
`software/webui/dist` directly.

The current release runs exactly one board per waveform job. It does not use
`SYNC_EPOCH` or `START_AT`, and multi-board requests are rejected before any
RFCTRL2 or waveform transport action. `sync_group`, board role, execution mode,
and the job-list request shape are retained only as the compatibility contract
for a future hardware-qualified synchronization mode.

Administrators can register boards, scan JTAG/UART and registered RFCTRL2
endpoints, bind stable `/dev/serial/by-id` paths, inspect read-only UART logs,
manage users, upload immutable `.bit + .elf` releases, and start controlled
temporary JTAG deployments. Ordinary users can acquire/release boards and can
perform real waveform operations only while holding the selected board lease.
Administrators must also hold the selected board lease for real waveform
operations; their elevated role does not bypass the control lock.

RFDC runtime configuration is hardware-confirmed without UART. The browser
sends NCO, Nyquist zone, NCO phase, and DAC output current through FastAPI as a
structured `RFCTRL2` UDP request. The PL applies those values through RFDC
AXI-Lite, verifies register readback, and returns actual quantized values in
`RFRESP2`. `data_amplitude`, `data_phase_deg`, and `data_offset_hz` remain host
IQ-generation parameters. A production board must advertise both PL RFDC
configuration capability bits; an older bitstream is rejected as unsupported.

For frontend development use `npm run dev -- --host 127.0.0.1` from
`software/webui`; Vite runs on port 5173 and proxies API requests to port 8000.
Do not set `RFSOC_WEB_SIMULATION=0` until the selected board's new RFCTRL2 PL
bitstream, IP mapping, channel outputs, register readback, and abort/mute
behavior have been verified. UART is optional and is never used to confirm a
runtime RFDC apply. See
[`WEB_CONSOLE_DEPLOYMENT.md`](WEB_CONSOLE_DEPLOYMENT.md) for production setup,
environment variables, permissions, and systemd units.

Use `send_waveform_udp.py` as the main waveform sender. It generates CH1-CH8
waveforms locally, saves the exact samples under `--output-dir`, uploads them to
the PL-side DDR image expected by the FPGA design, then sends BEGIN/PLAY pairs
for channels 1-8 followed by END. The default DDR layout is
`interleaved_512b`: every 512-bit DDR beat contains eight 64-bit lanes,
lane0=CH1 through lane7=CH8, and hardware packs four DDR beats into one
256-bit RFDC beat per channel. Legacy `tiled` and `contiguous` layouts remain
available only for debug/fallback flows.

The current custom hardware mapping drives one independent physical DAC output
per channel: CH1 -> `vout00`, CH2 -> `vout02`, CH3 -> `vout10`, CH4 -> `vout12`,
CH5 -> `vout20`, CH6 -> `vout22`, CH7 -> `vout30`, and CH8 -> `vout32`.

## Quick Start

Finite-length I/Q sine output:

```bash
python3 software/send_waveform_udp.py sine \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10 \
  --ch1-freq-hz 20000000 \
  --ch2-freq-hz 20000000 \
  --ch3-freq-hz 30000000 \
  --ch4-freq-hz 30000000 \
  --ch5-freq-hz 40000000 \
  --ch6-freq-hz 40000000 \
  --ch7-freq-hz 50000000 \
  --ch8-freq-hz 50000000 \
  --duration-s 1e-6
```

Legacy `--x-*` and `--y-*` options are still accepted as aliases for CH1 and
CH2.

Gaussian RF burst:

```bash
python3 software/send_waveform_udp.py burst \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10 \
  --ch1-freq-hz 80000000 \
  --ch2-freq-hz 120000000 \
  --ch3-freq-hz 80000000 \
  --ch4-freq-hz 120000000 \
  --ch5-freq-hz 80000000 \
  --ch6-freq-hz 120000000 \
  --ch7-freq-hz 80000000 \
  --ch8-freq-hz 120000000 \
  --duration-s 120e-9
```

Golden ILA/debug pattern:

```bash
python3 software/send_waveform_udp.py golden \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10
```

PL RISC-V control-plane V1 smoke commands:

```bash
# Send PING to the PL control path. Observe rv_dbg_status/last_seq in ila_udp_ddr.
python3 software/send_waveform_udp.py rvctrl-ping \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10 \
  --seq 1

# After waveform data is already in DDR, ask the PL control path to emit
# 8 interleaved PLAY instructions and END. This does not upload waveform data.
python3 software/send_waveform_udp.py rvctrl-play \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10 \
  --bytes-per-channel 4096 \
  --auto-start

# Generate a trigger through the PL control path.
python3 software/send_waveform_udp.py rvctrl-trigger \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10 \
  --seq 2
```

The V1 control path is parallel to the legacy waveform path. `WAVEDDR0` and
`WAVESTR0` still upload bulk data to DDR; `RVCTRL0\0` only carries small control
commands such as PING, PLAY_INTERLEAVED, and TRIGGER.

RVCTRL1 register-control smoke commands:

```bash
python3 software/send_waveform_udp.py rvctrl1-ping \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10 \
  --seq 10

python3 software/send_waveform_udp.py rvctrl1-mmio-write \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10 \
  --addr 0x120 \
  --value 0x00000001

python3 software/send_waveform_udp.py rvctrl1-mmio-batch \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10 \
  --write 0x120=0x00000001 \
  --write 0x124=0x00000002

python3 software/send_waveform_udp.py rvctrl1-trigger \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10

python3 software/send_waveform_udp.py rvctrl1-rfdc-ch-enable \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10 \
  --channel-mask 0xff \
  --enable-mask 0xff \
  --wait-response

python3 software/send_waveform_udp.py rvctrl1-rfdc-set-nco \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10 \
  --nco 1=100e6 \
  --zone 1=1 \
  --apply-mask 0x01 \
  --wait-response
```

`RVCTRL1` adds a versioned command envelope and MMIO-style operations. Bulk
waveform data remains on the direct `WAVEDDR0/WAVESTR0` DDR path and does not
pass through the RISC-V control path. `RVRESP1` is returned over UDP for
PING/STATUS/MMIO/PLAY/TRIGGER/RFDC control acknowledgements; MMIO reads return
the requested address and 32-bit value in the response payload.

PyPulse-style XY/Z/readout bundle with RFDC C2R I/Q lane packing:

```bash
python3 software/send_waveform_udp.py pypulse \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10 \
  --xy-freq-hz 90000000 \
  --readout-freq-hz 140000000 \
  --duration-s 120e-9 \
  --loop
```

In the normal ez-Q/GUI flow CH1-CH4 are XY, CH5-CH6 are Z, and CH7-CH8 are readout I/Q buffers.
Within every 256-bit RFDC AXIS word,
the 16 little-endian int16 lanes are interleaved as
`I0,Q0,I1,Q1,...,I7,Q7`. Each generated channel is uploaded as a logical
per-channel waveform, then mapped into the selected DDR layout before playback.

Scope test with all eight physical DAC outputs enabled:

```bash
python3 software/send_waveform_udp.py sine \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10 \
  --ch1-freq-hz 80000000 \
  --ch2-freq-hz 80000000 \
  --ch3-freq-hz 80000000 \
  --ch4-freq-hz 80000000 \
  --ch5-freq-hz 0 \
  --ch6-freq-hz 0 \
  --ch7-freq-hz 120000000 \
  --ch8-freq-hz 120000000 \
  --duration-s 1e-6
```

Dry run without touching the board:

```bash
python3 software/send_waveform_udp.py sine --dry-run --duration-s 1e-6 --ch1-freq-hz 80000000 --ch3-freq-hz 100000000
```

## Legacy Local GUI

The Tkinter GUI is retained only for compatibility/debug. Use the browser
console for board operation. Launch it from the repository root only when
needed:

```bash
python3 software/waveform_gui.py
```

If dependencies have not been installed yet, install the Python requirements
first:

```bash
python3 -m pip install -r software/requirements.txt
```

The GUI uses only standard-library `tkinter` plus the existing `matplotlib`
dependency. It provides separate panels for target connection settings, global
playback settings, independent CH1-CH8 waveform controls, artifact output, an
eight-channel waveform preview, and a status log. Each channel can choose only
`dc-iq-cw` or `iq-sine` independently, with a per-channel `Length (ns)` field, and
the right-side preview refreshes automatically after a short debounce when
relevant fields change. Dry run is enabled by default, so `Save / Dry Run` writes
the same artifact bundle as the CLI without sending UDP packets. The default NIC
binding is `enp225s0f0` with source IP `192.168.1.10`, matching the current 10G
bring-up host link. Use `Send to Board` only after confirming the target IP, UDP
port, NIC binding, source IP, finite waveform length, and trigger mode.

For the current custom XCZU47DR build, keep the GUI/global I/Q sample rate at
`400e6` and the AXIS/fabric rate at `50e6` unless the RFDC configuration
changes. The RFDC analog DAC sample rate target is `6.4e9`; the DAC IP then
applies 16x interpolation to the uploaded I/Q stream. The GUI sends
the same PL-side UDP waveform/control protocol as the CLI; it does not depend on
the removed PS Ethernet/lwIP firmware server.

The GUI always generates RFDC C2R interleaved I/Q buffers. `dc-iq-cw` writes a
constant I value with Q held at zero, so the RFDC fine NCO sets the emitted RF
tone. `iq-sine` writes quadrature I/Q samples with per-channel frequency, phase,
amplitude, and finite-length controls. The per-channel frequency is the RFDC
input baseband offset, not the final RF frequency. With the default 400 MS/s I/Q
rate, keep it within +/-160 MHz for this bring-up path; use the RFDC NCO to
place the RF center frequency. CH1 still maps to legacy upload argument `x`; CH2 maps to `y`;
CH3-CH8 map to `ch3` through `ch8`.

If launching from SSH or a non-desktop shell, `tkinter` needs a graphical display
(`DISPLAY`) or X11 forwarding. Without one, the GUI exits with a clear message
instead of a Python traceback.

For a non-display dependency smoke check, run:

```bash
python3 software/waveform_gui.py --smoke
```

## Important Parameters

- `--sample-rate-hz`: the RFDC input I/Q sample rate used to synthesize the
  sample array. For the current 6.4 GS/s, 16x interpolation RFDC build, this is
  400e6.
- `--ch1-freq-hz` through `--ch8-freq-hz`: baseband I/Q offsets in Hz.
- `--amplitude`: raw DAC code amplitude, from `0` to `32767`.
- `--duration-s`: finite I/Q sine record length. The generated record is rounded
  up to a whole 32B RFDC beat before upload/playback.
- `--zero-tail-s`: zero I/Q tail appended after `--duration-s` for finite sine
  records. This makes the RFDC output settle to zero instead of holding the last
  nonzero I/Q sample after `tvalid` stops.
- `--loop`: legacy debug option for non-sine modes. The `sine` mode and GUI
  finite waveform path force the END loop bit off.
- `--wait-for-trigger`: sends a non-auto-start END instruction and waits for an
  external/PS trigger instead of immediately playing.
- `--output-dir`: stores exact `.npy`, `.csv`, `.bin`, `.txt`, and metadata files
  for the samples that were uploaded.

The generated metadata includes `sample_rate_hz`, `record_duration_s`,
`samples_per_channel`, `bytes_per_channel`, and per-channel logical byte counts.
Check this file first when a frequency or length change appears to have no
effect.

## ILA Capture Report

After sending or saving a waveform bundle, use `ila_capture_report.py` to capture
the Vivado ILA and compare the RFDC-facing CH1-CH8 stream against the exact
Python artifacts. The script checks the trigger-to-valid delay, valid cycle
count, and every int16 sample carried by `dac_in_chN_tdata` while the channel's
gated valid signal is asserted.

End-to-end capture from a connected board. This checks whether a usable ILA is
already present; if not, it asks before programming the FPGA with the project
bitstream, arms the ILA, uploads the saved waveform artifacts, triggers playback,
exports the ILA CSV, and writes the reports:

```bash
python3 software/ila_capture_report.py \
  --capture \
  --send-after-arm \
  --artifact-dir software/waveform_out \
  --bit hardware/vivado/output/custom_xczu47dr_rfdc.bit \
  --ltx hardware/vivado/output/custom_xczu47dr_rfdc.ltx \
  --out-dir software/ila_reports \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10
```

Use `--program-mode never` when you are certain the board already has the right
design and you only want to attach the LTX. Use `--program-mode auto --yes` for
non-interactive lab runs where the script may program the board whenever the ILA
preflight check does not find this design. Add `--wait-for-trigger` when you want
the END instruction to wait for a host trigger packet instead of auto-starting.
If `software/waveform_out` is empty, the script automatically creates an eight-channel
golden/incrementing artifact bundle there before arming the ILA; pass
`--no-generate-default-artifacts` to require pre-existing artifacts instead.

If you already exported an ILA CSV from Vivado, run the same analysis offline:

```bash
python3 software/ila_capture_report.py \
  --csv software/ila_reports/ila_capture_report.csv \
  --artifact-dir software/waveform_out \
  --out-dir software/ila_reports
```

The default trigger reference is `top_i/pc_trig_start`, falling back to
`top_i/pc_trig_pulse`. The default valid probes are
`top_i/dac_chN_valid_gated`, and the default data probes are
`top_i/dac_in_chN_tdata`. If your regenerated ILA uses different probe names,
pass a flat JSON map with keys such as `trigger`, `ch1_valid`, and `ch1_data`
through `--probe-map`. To make delay checks strict, add
`--expected-delay-cycles ch1=0,ch2=0,ch3=0,ch4=0,ch5=0,ch6=0,ch7=0,ch8=0`; otherwise the report still
prints the observed delay but marks the expected-delay check as not evaluated.

The outputs are a Markdown report and a JSON detail file under `--out-dir`.

## Fixed Hardware Contract

Current GUI/CLI artifacts use `interleaved_512b` by default. For a finite record,
software zero-pads all eight channels to a shared logical duration, then packs
them into DDR as one continuous 512-bit stream:

- interleaved lane0..lane7 map to CH1..CH8
- each lane is 8 bytes: `I0,Q0,I1,Q1` as little-endian int16
- four 512-bit DDR beats reconstruct one 256-bit RFDC beat per channel
- PLAY length is per-channel logical bytes
- in interleaved mode all PLAY address offsets are `0`

Instruction word 0 is encoded as:

```text
bits [3:0]  opcode: 1=BEGIN/IDLE, 2=PLAY, 3=END
bits [7:4]  channel: 1=CH1 ... 8=CH8, 15=END auto-start
bit  [8]    loop enable on END
bit  [9]    tiled DDR layout on PLAY
bit  [10]   interleaved_512b DDR layout on PLAY
```

`send_waveform_udp.py` is the supported CLI entry point. Shared waveform
generation and protocol helpers live in `waveform_tools.py`.

The `ezq` subcommand accepts ez-Q-style `*_wave*.npy` / `*_seq.npy` artifacts
and uploads them through the same 10G DDR path after normalizing them into the
current interleaved_512b int16 layout.

## Verification

Run the Python protocol and waveform tests:

```bash
python3 -m unittest tests.test_waveform_tools tests.test_host_udp_waveform tests.test_golden_pattern_udp tests.test_waveform_gui_model
```
