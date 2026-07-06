# Software - RFSoC Waveform Sender

Use `send_waveform_udp.py` as the main waveform sender. It generates CH1-CH8
waveforms locally, saves the exact samples under `--output-dir`, uploads them to
the PL-side DDR image expected by the FPGA design, then sends BEGIN/PLAY pairs
for channels 1-8 followed by END. The default DDR layout is
`tiled`: each channel keeps independent 4 KiB tiles inside an 8-channel
32 KiB superblock. CH1 tile0 starts at `0x0`, CH2 tile0 at `0x1000`, and
CH1 tile1 at `0x8000`. The legacy contiguous slot layout remains available
with `--ddr-layout contiguous`; `interleaved_512b` remains available only when
explicitly selected for bandwidth/experimental flows.

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
  --sample-rate-hz 6000000000 \
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
  --sample-rate-hz 6000000000 \
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

PyPulse-style XY/Z/readout bundle with RFDC C2R I/Q lane packing:

```bash
python3 software/send_waveform_udp.py pypulse \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10 \
  --sample-rate-hz 6000000000 \
  --xy-freq-hz 90000000 \
  --readout-freq-hz 140000000 \
  --duration-s 120e-9 \
  --loop
```

In `pypulse` mode CH1/CH5 carry XY I/Q, CH2/CH6 carry Z with Q held at zero,
and CH3/CH4/CH7/CH8 carry readout I/Q buffers. Within every 256-bit RFDC AXIS word,
the 16 little-endian int16 lanes are interleaved as
`I0,Q0,I1,Q1,...,I7,Q7`. Each generated channel is uploaded as a logical
per-channel waveform, then mapped into the selected DDR layout before playback.

Scope test with all eight physical DAC outputs enabled:

```bash
python3 software/send_waveform_udp.py sine \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10 \
  --sample-rate-hz 6000000000 \
  --ch1-freq-hz 400000000 \
  --ch2-freq-hz 400000000 \
  --ch3-freq-hz 400000000 \
  --ch4-freq-hz 400000000 \
  --ch5-freq-hz 400000000 \
  --ch6-freq-hz 400000000 \
  --ch7-freq-hz 400000000 \
  --ch8-freq-hz 400000000 \
  --duration-s 1e-6
```

Dry run without touching the board:

```bash
python3 software/send_waveform_udp.py sine --dry-run --duration-s 1e-6 --ch1-freq-hz 80000000 --ch3-freq-hz 100000000
```

## Local GUI

Launch the local Tkinter GUI from the repository root:

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
`750e6` and the AXIS/fabric rate at `93.75e6` unless the RFDC configuration
changes. The RFDC analog DAC sample rate is `6.0e9`; the DAC IP then applies
8x interpolation to the uploaded I/Q stream. The GUI sends
the same PL-side UDP waveform/control protocol as the CLI; it does not depend on
the removed PS Ethernet/lwIP firmware server.

The GUI always generates RFDC C2R interleaved I/Q buffers. `dc-iq-cw` writes a
constant I value with Q held at zero, so the RFDC fine NCO sets the emitted RF
tone. `iq-sine` writes quadrature I/Q samples with per-channel frequency, phase,
amplitude, and finite-length controls. The per-channel frequency is the RFDC
input baseband offset, not the final RF frequency. With the default 750 MS/s I/Q
rate, keep it within +/-375 MHz; use the RFDC NCO to place the RF center
frequency. CH1 still maps to legacy upload argument `x`; CH2 maps to `y`;
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
  sample array. For the current 6.0 GS/s, 8x interpolation RFDC build, this is
  750e6.
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

Current GUI/CLI artifacts use a fixed 4096-byte record per channel by default.
The default upload layout is `tiled`, with one 4096-byte tile per channel
inside each 32768-byte superblock. The first tile for each channel is:

- `samples_per_channel = 2048` int16 samples
- `ch1_ddr_offset = 0x0000000000000000` → `vout00`
- `ch2_ddr_offset = 0x0000000000001000` → `vout02`
- `ch3_ddr_offset = 0x0000000000002000` → `vout10`
- `ch4_ddr_offset = 0x0000000000003000` → `vout12`
- `ch5_ddr_offset = 0x0000000000004000` → `vout20`
- `ch6_ddr_offset = 0x0000000000005000` → `vout22`
- `ch7_ddr_offset = 0x0000000000006000` → `vout30`
- `ch8_ddr_offset = 0x0000000000007000` → `vout32`
- PLAY length = `4096` bytes per channel
- next tile for the same channel = current tile address + `0x8000`

Instruction word 0 is encoded as:

```text
bits [3:0]  opcode: 1=BEGIN/IDLE, 2=PLAY, 3=END
bits [7:4]  channel: 1=CH1 ... 8=CH8, 15=END auto-start
bit  [8]    loop enable on END
bit  [9]    tiled DDR layout on PLAY
```

`send_waveform_udp.py` is the supported CLI entry point. Shared waveform
generation and protocol helpers live in `waveform_tools.py`.

The `ezq` subcommand accepts ez-Q-style `*_wave*.npy` / `*_seq.npy` artifacts
and uploads them through the same 10G DDR path after normalizing them into the
current tiled int16 layout.

## Verification

Run the Python protocol and waveform tests:

```bash
python3 -m unittest tests.test_waveform_tools tests.test_host_udp_waveform tests.test_golden_pattern_udp tests.test_waveform_gui_model
```
