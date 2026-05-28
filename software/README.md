# Software - RFSoC Waveform Sender

Use `send_waveform_udp.py` as the main waveform sender. It generates CH1-CH4
waveforms locally, saves the exact samples under `--output-dir`, uploads them to
the PL-side DDR offsets expected by the FPGA design, then sends BEGIN/PLAY pairs
for channels 1-4 followed by END. The current custom hardware mapping is CH1 ->
DDR `0x0` / DAC20, CH2 -> DDR `0x1000` / DAC22, CH3 -> DDR `0x2000` / DAC30,
and CH4 -> DDR `0x3000` / DAC32.

## Quick Start

Continuous sine output:

```bash
python3 software/send_waveform_udp.py sine \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10 \
  --sample-rate-hz 1200000000 \
  --ch1-freq-hz 20000000 \
  --ch2-freq-hz 20000000 \
  --ch3-freq-hz 30000000 \
  --ch4-freq-hz 30000000 \
  --loop
```

Legacy `--x-*` and `--y-*` options are still accepted as aliases for CH1 and
CH2.

Gaussian RF burst:

```bash
python3 software/send_waveform_udp.py burst \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10 \
  --sample-rate-hz 1200000000 \
  --ch1-freq-hz 80000000 \
  --ch2-freq-hz 120000000 \
  --ch3-freq-hz 80000000 \
  --ch4-freq-hz 120000000 \
  --duration-s 120e-9
```

Golden ILA/debug pattern:

```bash
python3 software/send_waveform_udp.py golden \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10
```

Dry run without touching the board:

```bash
python3 software/send_waveform_udp.py sine --dry-run --ch1-freq-hz 80000000 --ch3-freq-hz 100000000
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
playback settings, independent CH1-CH4 waveform controls, artifact output, a
four-channel waveform preview, and a status log. Each channel can
choose `off`, `quantum`, `pulse`, `sine`, `burst`, or `golden` independently, and
the right-side preview refreshes automatically after a short debounce when
relevant fields change. Dry run is enabled by default, so `Save / Dry Run` writes
the same artifact bundle as the CLI without sending UDP packets. The default NIC
binding is `enp225s0f0` with source IP `192.168.1.10`, matching the current 10G
bring-up host link. Use `Send to Board` only after confirming the target IP, UDP
port, NIC binding, source IP, loop mode, and trigger mode.

For the current custom XCZU47DR build, keep the GUI/global sample rate at
`1.2e9` unless the RFDC fabric/sample-rate configuration changes. The GUI sends
the same PL-side UDP waveform/control protocol as the CLI; it does not depend on
the removed PS Ethernet/lwIP firmware server.

For quantum-domain pulses, use the `quantum` channel type. The GUI follows the
usual two-quadrature control convention for CH1/CH2 while CH3/CH4 remain
independently configurable physical DAC records. An `x` gate emits a Gaussian
drive on CH1, a `y` gate emits a +90 degree quadrature drive on CH2, and a `z`
gate produces a paired positive/negative phase pulse. CH1 still maps to legacy
upload argument `x`; CH2 maps to `y`; CH3/CH4 map to `ch3`/`ch4`.

If launching from SSH or a non-desktop shell, `tkinter` needs a graphical display
(`DISPLAY`) or X11 forwarding. Without one, the GUI exits with a clear message
instead of a Python traceback.

For a non-display dependency smoke check, run:

```bash
python3 software/waveform_gui.py --smoke
```

## Important Parameters

- `--sample-rate-hz`: the DAC sample rate used to synthesize the sample array.
  This must match the actual RFDC output sample rate for the oscilloscope
  frequency to match `--chN-freq-hz`.
- `--ch1-freq-hz` through `--ch4-freq-hz`: tone/carrier frequencies in Hz.
- `--amplitude`: raw DAC code amplitude, from `0` to `32767`.
- `--loop`: sets the END instruction loop bit. The hardware then refills and
  replays the same DDR waveform continuously.
- `--wait-for-trigger`: sends a non-auto-start END instruction and waits for an
  external/PS trigger instead of immediately playing.
- `--output-dir`: stores exact `.npy`, `.csv`, `.bin`, `.txt`, and metadata files
  for the samples that were uploaded.

The generated metadata includes `sample_rate_hz`, `record_duration_s`,
`samples_per_channel`, `bytes_per_channel`, and the number of waveform cycles in
the 2048-sample record. Check this file first when a frequency change appears to
have no effect.

## ILA Capture Report

After sending or saving a waveform bundle, use `ila_capture_report.py` to capture
the Vivado ILA and compare the RFDC-facing CH1-CH4 stream against the exact
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
If `software/waveform_out` is empty, the script automatically creates a four-channel
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
`--expected-delay-cycles ch1=0,ch2=0,ch3=0,ch4=0`; otherwise the report still
prints the observed delay but marks the expected-delay check as not evaluated.

The outputs are a Markdown report and a JSON detail file under `--out-dir`.

## Fixed Hardware Contract

Current hardware uses a fixed 4096-byte record per channel:

- `samples_per_channel = 2048` int16 samples
- `ch1_ddr_offset = 0x0000000000000000` / DAC20
- `ch2_ddr_offset = 0x0000000000001000` / DAC22
- `ch3_ddr_offset = 0x0000000000002000` / DAC30
- `ch4_ddr_offset = 0x0000000000003000` / DAC32
- PLAY length = `4096` bytes per channel

Instruction word 0 is encoded as:

```text
bits [3:0]  opcode: 1=BEGIN/IDLE, 2=PLAY, 3=END
bits [7:4]  channel: 1=CH1, 2=CH2, 3=CH3, 4=CH4, 15=END auto-start
bit  [8]    loop enable on END
```

`send_waveform_udp.py` is the supported CLI entry point. Shared waveform
generation and protocol helpers live in `waveform_tools.py`.

## Verification

Run the Python protocol and waveform tests:

```bash
python3 -m unittest tests.test_waveform_tools tests.test_host_udp_waveform tests.test_golden_pattern_udp tests.test_waveform_gui_model
```
