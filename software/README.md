# Software - RFSoC Waveform Sender

Use `send_waveform_udp.py` as the main waveform sender. It generates the X/Y
waveforms locally, saves the exact samples under `--output-dir`, uploads them to
the PL-side DDR offsets expected by the FPGA design, then sends the standard
BEGIN/PLAY/BEGIN/PLAY/END instruction sequence.

## Quick Start

Continuous sine output:

```bash
python3 software/send_waveform_udp.py sine \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10 \
  --sample-rate-hz 4608000000 \
  --x-freq-hz 20000000 \
  --y-freq-hz 20000000 \
  --loop
```

Gaussian RF burst:

```bash
python3 software/send_waveform_udp.py burst \
  --ip 192.168.1.128 \
  --udp-interface enp225s0f0 \
  --udp-source-ip 192.168.1.10 \
  --sample-rate-hz 4608000000 \
  --x-freq-hz 80000000 \
  --y-freq-hz 120000000 \
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
python3 software/send_waveform_udp.py sine --dry-run --x-freq-hz 80000000
```

## Local GUI

Launch the local Tkinter GUI from the repository root:

```bash
python3 software/waveform_gui.py
```

The GUI uses only standard-library `tkinter` plus the existing `matplotlib`
dependency. It provides separate panels for target connection settings, global
playback settings, independent CH1 / DDR X and CH2 / DDR Y waveform controls,
artifact output, an I/Q waveform preview, and a status log. Each channel can
choose `off`, `quantum`, `pulse`, `sine`, `burst`, or `golden` independently, and
the right-side preview refreshes automatically after a short debounce when
relevant fields change. Dry run is enabled by default, so `Save / Dry Run` writes
the same artifact bundle as the CLI without sending UDP packets. The default NIC
binding is `enp225s0f0` with source IP `192.168.1.10`, matching the current 10G
bring-up host link. Use `Send to Board` only after confirming the target IP, UDP
port, NIC binding, source IP, loop mode, and trigger mode.

For quantum-domain pulses, use the `quantum` channel type. The GUI follows the
usual two-quadrature control convention: an `x` gate emits a Gaussian drive on the
I quadrature (CH1 / DDR X), a `y` gate emits a Gaussian drive on the Q quadrature
(CH2 / DDR Y), and a `z` gate is treated as a virtual Z frame phase update. The
virtual Z operation is recorded in metadata but emits zero DAC samples, because
the current FPGA upload path has two physical DAC records, not a third Z output.
CH1 always maps to DDR X and upload argument `x`; CH2 always maps to DDR Y and
upload argument `y`.

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
  frequency to match `--x-freq-hz` / `--y-freq-hz`.
- `--x-freq-hz`, `--y-freq-hz`: tone/carrier frequencies in Hz.
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

## Fixed Hardware Contract

Current hardware uses a fixed 4096-byte record per channel:

- `samples_per_channel = 2048` int16 samples
- `x_ddr_offset = 0x0000000000000000`
- `y_ddr_offset = 0x0000000000001000`
- PLAY length = `4096` bytes per channel

Instruction word 0 is encoded as:

```text
bits [3:0]  opcode: 1=BEGIN/IDLE, 2=PLAY, 3=END
bits [7:4]  channel: 1=X, 2=Y, 15=END auto-start
bit  [8]    loop enable on END
```

`send_waveform_udp.py` is the supported CLI entry point. Shared waveform
generation and protocol helpers live in `waveform_tools.py`.

## Verification

Run the Python protocol and waveform tests:

```bash
python3 -m unittest tests.test_waveform_tools tests.test_host_udp_waveform tests.test_golden_pattern_udp tests.test_waveform_gui_model
```
