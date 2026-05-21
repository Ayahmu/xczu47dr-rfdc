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

The old scripts `send_sine_wave_udp.py`, `send_xy_waveform_udp.py`, and
`send_golden_pattern_udp.py` are kept as compatibility wrappers. New tests and
new usage should target `waveform_tools.py` and `send_waveform_udp.py`.

## Verification

Run the Python protocol and waveform tests:

```bash
python3 -m unittest tests.test_waveform_tools tests.test_host_udp_waveform tests.test_golden_pattern_udp
```
