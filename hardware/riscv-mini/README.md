# PL RISC-V Mini Control Plane V1

V1 keeps the RFDC data path unchanged and adds a parallel PL control path:

```text
10G UDP RVCTRL0 packet -> udp_waveform_ddr_writer -> pl_riscv_control_v1
                        -> existing 128-bit playback instruction stream
```

`ucb-bar/riscv-mini` is intentionally kept as an independent generator because
the current project uses Mill + Scala 2.12 + Chisel 3.4, while riscv-mini uses a
newer SBT/Chisel stack. The synthesizable V1 path is
`hardware/vivado/src/pl_riscv_control_v1.v`; it implements the firmware-visible
control behavior as a stable shim. A generated riscv-mini Tile can later replace
the shim by driving the same local MMIO/instruction/trigger interface.

Pinned upstream:

- Repository: https://github.com/ucb-bar/riscv-mini
- HEAD recorded for this integration: `3eda724c437c73f3192fcbaaf76ae93b5eb870b0`

Fetch upstream sources for inspection/generation:

```bash
hardware/riscv-mini/scripts/fetch_riscv_mini.sh
```

The script clones upstream into ignored directory
`hardware/riscv-mini/vendor/ucb-bar-riscv-mini`.

Generate upstream `Tile.sv` into this project's ignored generated directory:

```bash
hardware/riscv-mini/scripts/generate_tile_sv.sh
```

This runs upstream `make compile`, then copies
`vendor/ucb-bar-riscv-mini/generated-src/Tile.sv` to
`hardware/riscv-mini/generated/Tile.sv`. The generated Tile is not wired into
`Top.v` in V1; the checked-in synthesizable control behavior is still
`pl_riscv_control_v1.v`.

## V1 Control Packet

UDP datagram:

```text
u64 magic       "RVCTRL0\0"
u64 word_count  low 32 bits = payload uint32 word count
u32 payload[word_count], little-endian, padded to 8B
```

Supported payload commands:

```text
PING:
  word0 = 0x00000001
  word1 = seq

PLAY_INTERLEAVED:
  word0 = 0x00000002
  word1 = seq
  word2 = bytes_per_channel, 32B aligned
  word3 = flags, bit0 auto_start, bit1 loop

TRIGGER:
  word0 = 0x00000003
  word1 = seq

WRITE_MMIO:
  word0 = 0x00000004
  word1 = seq
  word2 = address
  word3 = value
```

V1 does not move waveform data through RISC-V. Waveform data still uses the
existing `WAVEDDR0/WAVESTR0` DDR writer path.
