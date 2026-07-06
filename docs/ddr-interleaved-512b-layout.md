# DDR Interleaved 512-bit Layout

## Target

The default `TARGET=custom_xczu47dr_bw` builds this RFDC-prep DDR bandwidth path.
Use `TARGET=custom_xczu47dr` for the normal RFDC playback design.

## DDR Layout

Each DDR beat is 512 bits, split into eight 64-bit lanes:

| Byte Offset In Beat | Lane | Logical Channel |
| --- | --- | --- |
| `0..7` | lane0 | CH1 sample `N` |
| `8..15` | lane1 | CH2 sample `N` |
| `16..23` | lane2 | CH3 sample `N` |
| `24..31` | lane3 | CH4 sample `N` |
| `32..39` | lane4 | CH5 sample `N` |
| `40..47` | lane5 | CH6 sample `N` |
| `48..55` | lane6 | CH7 sample `N` |
| `56..63` | lane7 | CH8 sample `N` |

The next 512-bit beat stores CH1..CH8 sample `N+1`.

Firmware writes:

```c
ptr[i * 8 + ch] = channel_sample(ch + 1, i);
```

So the physical DDR address is:

```text
addr = base + sample_index * 64 + channel_index * 8
```

## PLAY Semantics

The firmware still emits eight PLAY instructions to preserve the Waveform
state-machine meaning of eight armed logical channels. In interleaved mode:

| Field | Value |
| --- | --- |
| PLAY channel | `1..8` |
| PLAY length | per-channel byte length |
| PLAY addr offset | `0` for all channels |
| first PLAY | locks the interleaved base address |
| total read bytes | `per_channel_length * 8` |

The DataMover then reads a single continuous DDR region.

## Bandwidth Counters

The authoritative bandwidth counter is in `TopBandwidthCore` at the DDR
controller AXI R channel:

```verilog
DDR_rvalid && DDR_rready
```

Each event adds 64 bytes. The UART `delta_bytes` field is this sampled DDR read
counter, not downstream sink consumption and not host-time-derived throughput.

## Commands

```bash
make hardware
make firmware
JTAG_CABLE_SERIAL=210512180081 make program
./software/capture_uart.sh /dev/ttyUSB1 120 logs/interleaved_pressure_mode
BW_LOG_DIR=/home/kyu/workspace/xczu47dr-rfdc/logs/interleaved_pressure_mode python3 software/dashboard_server.py
```

Expected sustained bandwidth for DDR4 x64 / AXI512 / 300 MHz UI is around
17-18 GB/s when the sink is in pressure mode and stalls remain near zero.
