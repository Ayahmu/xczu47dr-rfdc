import argparse
import hashlib
import json
import os
import socket
import struct
import time
from pathlib import Path

import numpy as np

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


# ============================================================
# 1. 硬件参数
# ============================================================
# 8 通道 NCO 数字上变频（IQ -> Real / C2R）配置：
#   每个 DAC tile 采样率 Fs = 6.4 GSPS，16 倍内插，
#   RFDC 输入复数 I/Q 样本率 = Fs / interp = 400 MSPS，
#   PL/AXIS 织物时钟 = Fs / interp / 8 = 50 MHz。
#   每个 256-bit AXIS 字 = 8 个 I/Q 复样本，lane 顺序为
#   I0,Q0,I1,Q1,...,I7,Q7；顶层将 8 个执行器通道分别送到 8 个
#   物理 DAC slice。
#   DDR 播放侧默认按 interleaved_512b 组织。每个 512-bit DDR beat
#   包含 8 路各一个 64-bit lane，硬件每 4 个 DDR beat 拼出 8 路
#   256-bit RFDC AXIS 字。网页运行时 NCO 由 PL RFCTRL2 闭环设置；下方
#   mailbox helpers 仅为旧桌面工具兼容，当前固件不会轮询这些区域。
#
# 当前硬件主线是单 dac_axis_clk + interleaved_512b，所有通道共享同一
# RFDC 输入采样率。CH7/CH8 的 Readout RF 频点通过 NCO/mailbox 调谐，
# 不是单独改变这两路的 DAC Fs。
DAC_TILE_FS = 6.4e9
DAC_INTERP = 16
DAC_IQ_SAMPLE_RATE_HZ = DAC_TILE_FS / DAC_INTERP
DAC_FABRIC_HZ = DAC_TILE_FS / DAC_INTERP / 8  # 50 MHz
NCO_FREQ_GHZ = 4.5  # 仅作默认记录，实际按通道由固件配置
DEFAULT_WAVEFORM_SAMPLE_RATE_HZ = DAC_IQ_SAMPLE_RATE_HZ
DEFAULT_AXIS_HZ = DAC_FABRIC_HZ
RFDC_INTERPOLATION = DAC_INTERP

# 单频 CW 的复基带置于 DC：I 为常数，Q 为 0。每个 256-bit RFDC
# AXIS 字按 I0,Q0,I1,Q1,...,I7,Q7 的 int16 lane 顺序写入 DDR。
TONE_AMP = 0.5  # 每路 lane 占满量程的比例（C = round(amp*32767)）
TONE_BYTES_DEFAULT = 256 * 1024  # 每通道 DDR 缓冲字节数（32B 对齐）
DDR_CH_STRIDE = TONE_BYTES_DEFAULT
BEAT_BYTES = 32
DDR_LAYOUT_CONTIGUOUS = "contiguous"
DDR_LAYOUT_INTERLEAVED_512B = "interleaved_512b"
DDR_LAYOUT_TILED = "tiled"
DEFAULT_DDR_LAYOUT = DDR_LAYOUT_INTERLEAVED_512B
MAX_LENGTH_PATTERN_CW_MARKER = "cw-marker"
MAX_LENGTH_PATTERN_LOWFREQ_SINE = "lowfreq-sine"
DDR_TILE_BYTES = FIXED_DATA_BYTES = 4096
DDR_TILE_CHANNELS = 8
DDR_SUPERBLOCK_BYTES = DDR_TILE_BYTES * DDR_TILE_CHANNELS
PLAY_FLAG_LOOP = 0x1
PLAY_FLAG_TILED = 0x2
PLAY_FLAG_INTERLEAVED = 0x4
DDR_INTERLEAVED_LANE_BYTES = 8
DDR_INTERLEAVED_BEAT_BYTES = DDR_INTERLEAVED_LANE_BYTES * DDR_TILE_CHANNELS
DDR_INTERLEAVED_CHANNELS = DDR_TILE_CHANNELS
DDR_PHYS_BYTES = 8 * 1024 * 1024 * 1024
DDR_RESERVED_TOP_BYTES = 1 * 1024 * 1024
DDR_USABLE_WAVEFORM_BYTES = DDR_PHYS_BYTES - DDR_RESERVED_TOP_BYTES
DDR_MAX_BYTES_PER_CHANNEL = (DDR_USABLE_WAVEFORM_BYTES // DDR_INTERLEAVED_CHANNELS) & ~(BEAT_BYTES - 1)
DDR_MAX_INTERLEAVED_BYTES = DDR_MAX_BYTES_PER_CHANNEL * DDR_INTERLEAVED_CHANNELS
DEFAULT_RECORD_DURATION_S = 10e-6
DEFAULT_BASEBAND_OFFSET_LIMIT_HZ = 160e6
DEFAULT_XY_TARGET_RF_HZ = 4.5e9
DEFAULT_READOUT_TARGET_RF_HZ = {
    7: 5.8e9,
    8: 6.2e9,
}

CHANNEL_ROLES = {
    1: "xy",
    2: "xy",
    3: "xy",
    4: "xy",
    5: "z",
    6: "z",
    7: "readout",
    8: "readout",
}

DDR_BASE = 0x0000000000000000
DDR_CH1_ADDR = DDR_BASE
DDR_CH2_ADDR = DDR_CH1_ADDR + DDR_CH_STRIDE
DDR_CH3_ADDR = DDR_CH2_ADDR + DDR_CH_STRIDE
DDR_CH4_ADDR = DDR_CH3_ADDR + DDR_CH_STRIDE
DDR_CH5_ADDR = DDR_CH4_ADDR + DDR_CH_STRIDE
DDR_CH6_ADDR = DDR_CH5_ADDR + DDR_CH_STRIDE
DDR_CH7_ADDR = DDR_CH6_ADDR + DDR_CH_STRIDE
DDR_CH8_ADDR = DDR_CH7_ADDR + DDR_CH_STRIDE
DDR_CH_ADDR = [
    DDR_CH1_ADDR,
    DDR_CH2_ADDR,
    DDR_CH3_ADDR,
    DDR_CH4_ADDR,
    DDR_CH5_ADDR,
    DDR_CH6_ADDR,
    DDR_CH7_ADDR,
    DDR_CH8_ADDR,
]
DDR_X_ADDR = DDR_CH1_ADDR
DDR_Y_ADDR = DDR_CH2_ADDR
# Backward-compatible aliases used by older GUI/tests. DAC_XY_FS is the RFDC
# input I/Q sample rate used for waveform synthesis, not the post-interpolation
# analog DAC sample rate.
DAC_XY_FS = DEFAULT_WAVEFORM_SAMPLE_RATE_HZ
DAC_AXIS_HZ = DEFAULT_AXIS_HZ
# 单帧固定字节数 / 样本数：一个 256-bit DAC 字 = 32B = 16 个 int16 lane。
NUM_SAMPLES = FIXED_DATA_BYTES // 2
INT16_PER_BEAT = 16
INT16_PER_DACWORD = 16
IQ_LANES_PER_COMPONENT = INT16_PER_DACWORD // 2

DEFAULT_BOARD_IP = os.environ.get("RFSOC_BOARD_IP", "192.168.1.128")
DEFAULT_BOARD_PORT = int(os.environ.get("RFSOC_BOARD_PORT", "1234"))
DEFAULT_UDP_WRITE_SETTLE_S = float(os.environ.get("RFSOC_UDP_WRITE_SETTLE_S", "0.25"))
DEFAULT_UDP_INTERFACE = os.environ.get("RFSOC_UDP_INTERFACE", "")
DEFAULT_UDP_SOURCE_IP = os.environ.get("RFSOC_UDP_SOURCE_IP", "")
DEFAULT_WAVEFORM_CACHE_DIR = Path(os.environ.get("RFSOC_WAVEFORM_CACHE_DIR", "/tmp/opencode/rfsoc_waveform_cache"))
SO_BINDTODEVICE = 25
UDP_WAVE_DDR_MAGIC = 0x5741564544445230  # WAVEDDR0
UDP_WAVE_BULK_MAGIC = 0x5741564553545230  # WAVESTR0
UDP_TRIGGER_WORD = 0x3152454747495254  # ASCII "TRIGGER1" on the UDP byte stream
UDP_RVCTRL_MAGIC = 0x00304C5254435652  # ASCII "RVCTRL0\\0" on the UDP byte stream
UDP_RVCTRL1_MAGIC = 0x00314C5254435652  # ASCII "RVCTRL1\\0" on the UDP byte stream
UDP_RVRESP1_MAGIC = 0x0031505345525652  # ASCII "RVRESP1\\0" on the UDP byte stream
RVCTRL1_VERSION = 1
UDP_RFCTRL2_MAGIC = 0x00324C5254434652  # ASCII "RFCTRL2\\0" on the UDP byte stream
UDP_RFRESP2_MAGIC = 0x0032505345524652  # ASCII "RFRESP2\\0" on the UDP byte stream
RFCTRL2_VERSION = 2
RV_CMD_PING = 0x00000001
RV_CMD_PLAY_INTERLEAVED = 0x00000002
RV_CMD_TRIGGER = 0x00000003
RV_CMD_WRITE_MMIO = 0x00000004
RV1_OP_PING = 0x00000001
RV1_OP_MMIO_READ32 = 0x00000002
RV1_OP_MMIO_WRITE32 = 0x00000003
RV1_OP_MMIO_RMW32 = 0x00000004
RV1_OP_MMIO_BATCH = 0x00000005
RV1_OP_PLAY_INTERLEAVED = 0x00000006
RV1_OP_TRIGGER = 0x00000007
RV1_OP_RFDC_CH_ENABLE = 0x00000008
RV1_OP_RFDC_SET_NCO = 0x00000009
RV1_OP_STATUS_READ = 0x0000000A
RF2_OP_HELLO = 0x00000001
RF2_OP_STATUS = 0x00000002
RF2_OP_RFDC_APPLY = 0x00000003
# Kept as a source-compatible name for older scripts. Opcode 0x03 now always
# means the structured PL RFDC apply command, never the old fake SET_NCO path.
RF2_OP_SET_NCO = RF2_OP_RFDC_APPLY
RF2_OP_UPLOAD_BEGIN = 0x00000004
RF2_OP_UPLOAD_COMMIT = 0x00000005
RF2_OP_ARM = 0x00000006
RF2_OP_SYNC_EPOCH = 0x00000007
RF2_OP_START_AT = 0x00000008
RF2_OP_TRIGGER = 0x00000009
RF2_OP_ABORT_MUTE = 0x0000000A
RF2_OP_RFDC_GET_CONFIG = 0x0000000B

RF2_CAP_PL_RFDC_CONFIG = 0x00010000
RF2_CAP_RFDC_GET_CONFIG = 0x00020000
RF2_STATUS_RFDC_READY = 0x00000001
RF2_STATUS_RFDC_BUSY = 0x00000002
RF2_STATUS_ARMED = 0x00000004
RF2_STATUS_RUNNING = 0x00000008

RF2_STATUS_OK = 0x0000
RF2_STATUS_BAD_VERSION = 0x0001
RF2_STATUS_UNSUPPORTED = 0x0002
RF2_STATUS_BAD_REQUEST = 0x0003
RF2_STATUS_BUSY = 0x0004
RF2_STATUS_RFDC_NOT_READY = 0x0005
RF2_STATUS_UNSAFE_STATE = 0x0006
RF2_STATUS_RANGE = 0x0007
RF2_STATUS_AXI_ERROR = 0x0008
RF2_STATUS_AXI_TIMEOUT = 0x0009
RF2_STATUS_READBACK = 0x000A
RF2_STATUS_PARTIAL = 0x000B

RFDC_APPLY_CHANNELS = 8
RFDC_APPLY_REQUEST_HEADER_BYTES = 8
RFDC_APPLY_REQUEST_ENTRY_BYTES = 24
RFDC_APPLY_RESPONSE_HEADER_BYTES = 32
RFDC_APPLY_RESPONSE_ENTRY_BYTES = 40
RFDC_NCO_MIN_HZ = -3_200_000_000
RFDC_NCO_MAX_HZ = 3_200_000_000
RV_PLAY_FLAG_AUTO_START = 0x1
RV_PLAY_FLAG_LOOP = 0x2
RFDC_CTRL_MAILBOX_OFFSET = DDR_MAX_INTERLEAVED_BYTES
RFDC_CTRL_MAILBOX_MAGIC = 0x304F434E43444652  # ASCII "RFDCNCO0" little-endian
RFDC_CTRL_MAILBOX_HEADER_BYTES = 32
RFDC_CTRL_MAILBOX_ENTRY_BYTES = 16
RFDC_CTRL_MAILBOX_CHANNELS = 8
RFDC_CTRL_MAILBOX_BYTES = RFDC_CTRL_MAILBOX_HEADER_BYTES + RFDC_CTRL_MAILBOX_ENTRY_BYTES * RFDC_CTRL_MAILBOX_CHANNELS
RFDC_CTRL_MAILBOX_FLAG_APPLY_IMMEDIATE = 0x1
RFDC_RUNTIME_MAILBOX_MAGIC = 0x31474643444652  # ASCII "RFDCFG1" little-endian
RFDC_RUNTIME_MAILBOX_HEADER_BYTES = 32
RFDC_RUNTIME_MAILBOX_ENTRY_BYTES = 32
RFDC_RUNTIME_MAILBOX_BYTES = RFDC_RUNTIME_MAILBOX_HEADER_BYTES + RFDC_RUNTIME_MAILBOX_ENTRY_BYTES * RFDC_CTRL_MAILBOX_CHANNELS


def rfdc_nco_plan_for_target(target_rf_hz: float, dac_fs_hz: float = DAC_TILE_FS) -> dict[str, float | int | str]:
    """Map an analog RF target to the C2R fine-NCO setting used by this design."""
    target = float(target_rf_hz)
    fs = float(dac_fs_hz)
    if target < 0.0 or target > fs:
        raise ValueError(f"target RF frequency must be in [0, Fs], got {target:g} Hz for Fs={fs:g} Hz")
    if target < fs / 2.0:
        return {
            "target_rf_hz": target,
            "nco_hz": target,
            "nyquist_zone": 1,
            "image": "direct",
        }
    return {
        "target_rf_hz": target,
        "nco_hz": target - fs,
        "nyquist_zone": 2,
        "image": "zone2",
    }


def pack_rfdc_nco_mailbox(
    per_channel_nco_hz: dict[int, float] | dict[str, float],
    per_channel_nyquist_zone: dict[int, int] | dict[str, int],
    seq: int,
    apply_mask: int = 0xFF,
    flags: int = RFDC_CTRL_MAILBOX_FLAG_APPLY_IMMEDIATE,
) -> bytes:
    """Pack one RFDC runtime-retune mailbox image.

    Layout is little-endian and intentionally header-last friendly:
      header 32B: magic u64, seq u32, apply_mask u32, flags u32, reserved[12]
      entries:    8 x {int64 nco_hz, uint32 nyquist_zone, uint32 reserved}
    """

    def _get(mapping, channel: int, default):
        return mapping.get(channel, mapping.get(f"ch{channel}", default))

    entries = bytearray()
    for channel in range(1, RFDC_CTRL_MAILBOX_CHANNELS + 1):
        nco_hz = int(round(float(_get(per_channel_nco_hz, channel, 0.0))))
        zone = int(_get(per_channel_nyquist_zone, channel, 1))
        if zone not in (1, 2):
            raise ValueError(f"RFDC mailbox CH{channel} nyquist_zone must be 1 or 2, got {zone}")
        entries += struct.pack("<qII", nco_hz, zone, 0)

    header = struct.pack(
        "<QIII12s",
        RFDC_CTRL_MAILBOX_MAGIC,
        int(seq) & 0xFFFFFFFF,
        int(apply_mask) & 0xFF,
        int(flags) & 0xFFFFFFFF,
        b"\x00" * 12,
    )
    image = header + bytes(entries)
    if len(image) != RFDC_CTRL_MAILBOX_BYTES:
        raise AssertionError("RFDC mailbox packing produced an unexpected size")
    return image


def iter_rfdc_nco_mailbox_packets(
    per_channel_nco_hz: dict[int, float] | dict[str, float],
    per_channel_nyquist_zone: dict[int, int] | dict[str, int],
    seq: int,
    apply_mask: int = 0xFF,
    flags: int = RFDC_CTRL_MAILBOX_FLAG_APPLY_IMMEDIATE,
    mailbox_offset: int = RFDC_CTRL_MAILBOX_OFFSET,
):
    """Yield UDP DDR write packets for a mailbox update, committing header last."""
    image = pack_rfdc_nco_mailbox(
        per_channel_nco_hz,
        per_channel_nyquist_zone,
        seq=seq,
        apply_mask=apply_mask,
        flags=flags,
    )
    entries = image[RFDC_CTRL_MAILBOX_HEADER_BYTES:]
    header = image[:RFDC_CTRL_MAILBOX_HEADER_BYTES]
    yield from iter_udp_waveform_packets(entries, mailbox_offset + RFDC_CTRL_MAILBOX_HEADER_BYTES)
    yield from iter_udp_waveform_packets(header, mailbox_offset)


def pack_rfdc_runtime_mailbox(
    per_channel_nco_hz: dict[int, float] | dict[str, float],
    per_channel_nyquist_zone: dict[int, int] | dict[str, int],
    per_channel_phase_deg: dict[int, float] | dict[str, float],
    per_channel_output_current_ma: dict[int, float] | dict[str, float],
    seq: int,
    apply_mask: int = 0xFF,
    flags: int = RFDC_CTRL_MAILBOX_FLAG_APPLY_IMMEDIATE,
) -> bytes:
    """Pack the runtime RFDC configuration mailbox used by the web console.

    Each entry is 32 bytes: signed NCO Hz, Nyquist zone, phase in milli-degrees,
    DAC output current in microamps, and reserved words. The header is written
    last by the packet iterator so firmware never observes a partial update.
    """
    def get(mapping, channel: int, default):
        return mapping.get(channel, mapping.get(f"ch{channel}", default))

    entries = bytearray()
    for channel in range(1, RFDC_CTRL_MAILBOX_CHANNELS + 1):
        nco_hz = int(round(float(get(per_channel_nco_hz, channel, 0.0))))
        zone = int(get(per_channel_nyquist_zone, channel, 1))
        phase_mdeg = int(round(float(get(per_channel_phase_deg, channel, 0.0)) * 1000.0))
        current_ua = int(round(float(get(per_channel_output_current_ma, channel, 20.0)) * 1000.0))
        if zone not in (1, 2):
            raise ValueError(f"RFDC runtime CH{channel} nyquist_zone must be 1 or 2")
        if not 2250 <= current_ua <= 40500:
            raise ValueError(f"RFDC runtime CH{channel} output current must be 2.25..40.5 mA")
        entries += struct.pack("<qIiIIII", nco_hz, zone, phase_mdeg, current_ua, 0, 0, 0)
    header = struct.pack(
        "<QIII12s", RFDC_RUNTIME_MAILBOX_MAGIC, int(seq) & 0xFFFFFFFF,
        int(apply_mask) & 0xFF, int(flags) & 0xFFFFFFFF, b"\x00" * 12,
    )
    image = header + bytes(entries)
    if len(image) != RFDC_RUNTIME_MAILBOX_BYTES:
        raise AssertionError("RFDC runtime mailbox has an unexpected size")
    return image


def iter_rfdc_runtime_mailbox_packets(
    per_channel_nco_hz, per_channel_nyquist_zone, per_channel_phase_deg,
    per_channel_output_current_ma, seq: int, apply_mask: int = 0xFF,
    flags: int = RFDC_CTRL_MAILBOX_FLAG_APPLY_IMMEDIATE,
    mailbox_offset: int = RFDC_CTRL_MAILBOX_OFFSET,
):
    image = pack_rfdc_runtime_mailbox(
        per_channel_nco_hz, per_channel_nyquist_zone, per_channel_phase_deg,
        per_channel_output_current_ma, seq=seq, apply_mask=apply_mask, flags=flags,
    )
    yield from iter_udp_waveform_packets(image[RFDC_RUNTIME_MAILBOX_HEADER_BYTES:], mailbox_offset + RFDC_RUNTIME_MAILBOX_HEADER_BYTES)
    yield from iter_udp_waveform_packets(image[:RFDC_RUNTIME_MAILBOX_HEADER_BYTES], mailbox_offset)


def pack_rvctrl_packet(words32: list[int] | tuple[int, ...]) -> bytes:
    """Pack one PL RISC-V control command UDP datagram.

    Datagram layout:
      u64 magic = "RVCTRL0\\0"
      u64 word_count, low 32 bits only
      payload = little-endian uint32 words, padded to an 8B boundary
    """
    words = [int(word) & 0xFFFFFFFF for word in words32]
    if not words:
        raise ValueError("RVCTRL payload must contain at least one 32-bit word")
    payload = struct.pack("<" + "I" * len(words), *words)
    if len(payload) % 8 != 0:
        payload += b"\x00" * (8 - (len(payload) % 8))
    return struct.pack("<QQ", UDP_RVCTRL_MAGIC, len(words)) + payload


def pack_rvctrl_ping(seq: int = 1) -> bytes:
    return pack_rvctrl_packet([RV_CMD_PING, int(seq)])


def pack_rvctrl_play_interleaved(
    bytes_per_channel: int,
    seq: int = 1,
    auto_start: bool = True,
    loop: bool = False,
) -> bytes:
    require_beat_aligned(bytes_per_channel, "bytes_per_channel")
    flags = (RV_PLAY_FLAG_AUTO_START if auto_start else 0) | (RV_PLAY_FLAG_LOOP if loop else 0)
    return pack_rvctrl_packet([RV_CMD_PLAY_INTERLEAVED, int(seq), int(bytes_per_channel), flags])


def pack_rvctrl_trigger(seq: int = 1) -> bytes:
    return pack_rvctrl_packet([RV_CMD_TRIGGER, int(seq)])


def pack_rvctrl_write_mmio(addr: int, value: int, seq: int = 1) -> bytes:
    return pack_rvctrl_packet([RV_CMD_WRITE_MMIO, int(seq), int(addr), int(value)])


def pack_rvctrl1_packet(opcode: int, payload: bytes = b"", seq: int = 1, flags: int = 0) -> bytes:
    """Pack one RVCTRL1 command datagram.

    Layout:
      u64 magic = "RVCTRL1\\0"
      u64 hdr0  = version[15:0], flags[15:0], opcode[31:0]
      u64 hdr1  = seq[31:0], payload_bytes[31:0]
      payload padded to 8B
    """
    raw_payload = bytes(payload)
    payload_bytes = len(raw_payload)
    payload = raw_payload
    if len(payload) % 8:
        payload += b"\x00" * (8 - (len(payload) % 8))
    hdr0 = ((int(opcode) & 0xFFFFFFFF) << 32) | ((int(flags) & 0xFFFF) << 16) | RVCTRL1_VERSION
    hdr1 = ((payload_bytes & 0xFFFFFFFF) << 32) | (int(seq) & 0xFFFFFFFF)
    return struct.pack("<QQQ", UDP_RVCTRL1_MAGIC, hdr0, hdr1) + payload


def pack_rvctrl1_ping(seq: int = 1) -> bytes:
    return pack_rvctrl1_packet(RV1_OP_PING, seq=seq)


def pack_rvctrl1_mmio_read32(addr: int, seq: int = 1) -> bytes:
    return pack_rvctrl1_packet(RV1_OP_MMIO_READ32, struct.pack("<I", int(addr) & 0xFFFFFFFF), seq=seq)


def pack_rvctrl1_mmio_write32(addr: int, value: int, seq: int = 1) -> bytes:
    return pack_rvctrl1_packet(
        RV1_OP_MMIO_WRITE32,
        struct.pack("<II", int(addr) & 0xFFFFFFFF, int(value) & 0xFFFFFFFF),
        seq=seq,
    )


def pack_rvctrl1_mmio_rmw32(addr: int, mask: int, value: int, seq: int = 1) -> bytes:
    return pack_rvctrl1_packet(
        RV1_OP_MMIO_RMW32,
        struct.pack("<III", int(addr) & 0xFFFFFFFF, int(mask) & 0xFFFFFFFF, int(value) & 0xFFFFFFFF),
        seq=seq,
    )


def pack_rvctrl1_mmio_batch(writes: list[tuple[int, int]] | tuple[tuple[int, int], ...], seq: int = 1) -> bytes:
    payload = bytearray(struct.pack("<I", len(writes)))
    for addr, value in writes:
        payload += struct.pack("<II", int(addr) & 0xFFFFFFFF, int(value) & 0xFFFFFFFF)
    return pack_rvctrl1_packet(RV1_OP_MMIO_BATCH, bytes(payload), seq=seq)


def pack_rvctrl1_play_interleaved(
    bytes_per_channel: int,
    seq: int = 1,
    auto_start: bool = True,
    loop: bool = False,
) -> bytes:
    require_beat_aligned(bytes_per_channel, "bytes_per_channel")
    flags = (RV_PLAY_FLAG_AUTO_START if auto_start else 0) | (RV_PLAY_FLAG_LOOP if loop else 0)
    return pack_rvctrl1_packet(
        RV1_OP_PLAY_INTERLEAVED,
        struct.pack("<II", int(bytes_per_channel) & 0xFFFFFFFF, flags),
        seq=seq,
    )


def pack_rvctrl1_trigger(seq: int = 1) -> bytes:
    return pack_rvctrl1_packet(RV1_OP_TRIGGER, seq=seq)


def pack_rvctrl1_rfdc_ch_enable(channel_mask: int, enable_mask: int, seq: int = 1) -> bytes:
    return pack_rvctrl1_packet(
        RV1_OP_RFDC_CH_ENABLE,
        struct.pack("<II", int(channel_mask) & 0xFF, int(enable_mask) & 0xFF),
        seq=seq,
    )


def pack_rvctrl1_rfdc_set_nco(
    per_channel_nco_hz: dict[int, float] | dict[str, float],
    per_channel_nyquist_zone: dict[int, int] | dict[str, int],
    seq: int = 1,
    apply_mask: int = 0xFF,
) -> bytes:
    def _get(mapping, channel: int, default):
        return mapping.get(channel, mapping.get(f"ch{channel}", default))

    payload = bytearray(struct.pack("<I", int(apply_mask) & 0xFF))
    for channel in range(1, RFDC_CTRL_MAILBOX_CHANNELS + 1):
        nco_hz = int(round(float(_get(per_channel_nco_hz, channel, 0.0))))
        zone = int(_get(per_channel_nyquist_zone, channel, 1))
        if zone not in (1, 2):
            raise ValueError(f"RVCTRL1 NCO CH{channel} nyquist_zone must be 1 or 2, got {zone}")
        payload += struct.pack("<qII", nco_hz, zone, 0)
    return pack_rvctrl1_packet(RV1_OP_RFDC_SET_NCO, bytes(payload), seq=seq)


def pack_rvctrl1_status_read(seq: int = 1) -> bytes:
    return pack_rvctrl1_packet(RV1_OP_STATUS_READ, seq=seq)


def parse_rvresp1_packet(packet: bytes) -> dict[str, int | bytes]:
    if len(packet) < 24:
        raise ValueError("RVRESP1 packet is too short")
    magic, hdr0, hdr1 = struct.unpack("<QQQ", packet[:24])
    if magic != UDP_RVRESP1_MAGIC:
        raise ValueError(f"unexpected RVRESP1 magic 0x{magic:016X}")
    payload_bytes = (hdr1 >> 32) & 0xFFFFFFFF
    if len(packet) < 24 + payload_bytes:
        raise ValueError(f"RVRESP1 payload is truncated: expected {payload_bytes} bytes")
    payload = packet[24:24 + payload_bytes]
    return {
        "version": hdr0 & 0xFFFF,
        "status": (hdr0 >> 16) & 0xFFFF,
        "opcode": (hdr0 >> 32) & 0xFFFFFFFF,
        "seq": hdr1 & 0xFFFFFFFF,
        "payload_bytes": payload_bytes,
        "payload": payload,
    }


def pack_rfctrl2_packet(opcode: int, payload: bytes = b"", seq: int = 1, flags: int = 0) -> bytes:
    """Pack a versioned multi-board RFCTRL2 UDP command."""
    raw_payload = bytes(payload)
    padded_payload = raw_payload
    if len(padded_payload) % 8:
        padded_payload += b"\x00" * (8 - (len(padded_payload) % 8))
    hdr0 = ((int(opcode) & 0xFFFFFFFF) << 32) | ((int(flags) & 0xFFFF) << 16) | RFCTRL2_VERSION
    hdr1 = ((len(raw_payload) & 0xFFFFFFFF) << 32) | (int(seq) & 0xFFFFFFFF)
    return struct.pack("<QQQ", UDP_RFCTRL2_MAGIC, hdr0, hdr1) + padded_payload


def pack_rfctrl2_hello(seq: int = 1) -> bytes:
    return pack_rfctrl2_packet(RF2_OP_HELLO, seq=seq)


def pack_rfctrl2_status(seq: int = 1) -> bytes:
    return pack_rfctrl2_packet(RF2_OP_STATUS, seq=seq)


def normalize_rfdc_phase_mdeg(phase_deg: float) -> int:
    """Normalize a mixer phase to the signed RFDC -180..180 degree range."""
    phase = ((float(phase_deg) + 180.0) % 360.0) - 180.0
    return int(round(phase * 1000.0))


def _rfdc_channel_value(mapping, channel: int, default):
    if isinstance(mapping, dict):
        return mapping.get(channel, mapping.get(f"ch{channel}", default))
    values = list(mapping)
    if len(values) != RFDC_APPLY_CHANNELS:
        raise ValueError("RFDC configuration requires exactly eight channel values")
    return values[channel - 1]


def pack_rfctrl2_rfdc_apply(
    per_channel_nco_hz,
    per_channel_nyquist_zone,
    per_channel_phase_deg,
    per_channel_output_current_ma,
    revision: int,
    channel_mask: int = 0xFF,
    seq: int = 1,
) -> bytes:
    """Pack the fixed CH1..CH8 structured RFDC runtime request.

    Payload layout (little-endian):
      u32 revision, u32 channel_mask
      8 x {s64 nco_hz, u32 nyquist_zone, s32 phase_mdeg,
           u32 dac_output_current_ua, u32 reserved}
    """
    mask = int(channel_mask)
    if mask < 1 or mask > 0xFF:
        raise ValueError(f"RFDC channel_mask must select CH1..CH8, got 0x{mask:X}")
    payload = bytearray(struct.pack("<II", int(revision) & 0xFFFFFFFF, mask))
    for channel in range(1, RFDC_APPLY_CHANNELS + 1):
        nco_hz = int(round(float(_rfdc_channel_value(per_channel_nco_hz, channel, 0.0))))
        if not RFDC_NCO_MIN_HZ <= nco_hz <= RFDC_NCO_MAX_HZ:
            raise ValueError(
                f"RFDC CH{channel} nco_hz must be in [{RFDC_NCO_MIN_HZ}, {RFDC_NCO_MAX_HZ}]"
            )
        zone = int(_rfdc_channel_value(per_channel_nyquist_zone, channel, 1))
        if zone not in (1, 2):
            raise ValueError(f"RFDC CH{channel} nyquist_zone must be 1 or 2")
        phase_mdeg = normalize_rfdc_phase_mdeg(
            float(_rfdc_channel_value(per_channel_phase_deg, channel, 0.0))
        )
        current_ua = int(round(
            float(_rfdc_channel_value(per_channel_output_current_ma, channel, 20.0)) * 1000.0
        ))
        current_min, current_max = ((6400, 32000) if channel in (5, 6) else (2250, 40500))
        if not current_min <= current_ua <= current_max:
            coupling = "DC" if channel in (5, 6) else "AC"
            raise ValueError(
                f"RFDC CH{channel} {coupling}-coupled DAC current must be in "
                f"[{current_min / 1000:g}, {current_max / 1000:g}] mA"
            )
        payload += struct.pack("<qIiII", nco_hz, zone, phase_mdeg, current_ua, 0)
    if len(payload) != RFDC_APPLY_REQUEST_HEADER_BYTES + RFDC_APPLY_CHANNELS * RFDC_APPLY_REQUEST_ENTRY_BYTES:
        raise AssertionError("RFDC apply request packing produced an unexpected size")
    return pack_rfctrl2_packet(RF2_OP_RFDC_APPLY, payload, seq=seq)


def pack_rfctrl2_rfdc_get_config(seq: int = 1) -> bytes:
    return pack_rfctrl2_packet(RF2_OP_RFDC_GET_CONFIG, seq=seq)


def pack_rfctrl2_arm(run_id: int, channel_mask: int = 0xFF, seq: int = 1) -> bytes:
    return pack_rfctrl2_packet(
        RF2_OP_ARM,
        struct.pack("<II", int(run_id) & 0xFFFFFFFF, int(channel_mask) & 0xFF),
        seq=seq,
    )


def pack_rfctrl2_sync_epoch(epoch: int, seq: int = 1) -> bytes:
    return pack_rfctrl2_packet(RF2_OP_SYNC_EPOCH, struct.pack("<Q", int(epoch) & 0xFFFFFFFFFFFFFFFF), seq=seq)


def pack_rfctrl2_start_at(start_tick: int, seq: int = 1) -> bytes:
    return pack_rfctrl2_packet(RF2_OP_START_AT, struct.pack("<Q", int(start_tick) & 0xFFFFFFFFFFFFFFFF), seq=seq)


def pack_rfctrl2_trigger(seq: int = 1) -> bytes:
    return pack_rfctrl2_packet(RF2_OP_TRIGGER, seq=seq)


def pack_rfctrl2_abort_mute(seq: int = 1) -> bytes:
    return pack_rfctrl2_packet(RF2_OP_ABORT_MUTE, seq=seq)


def parse_rfresp2_packet(packet: bytes) -> dict[str, int | bytes]:
    if len(packet) < 24:
        raise ValueError("RFRESP2 packet is too short")
    magic, hdr0, hdr1 = struct.unpack("<QQQ", packet[:24])
    if magic != UDP_RFRESP2_MAGIC:
        raise ValueError(f"unexpected RFRESP2 magic 0x{magic:016X}")
    payload_bytes = (hdr1 >> 32) & 0xFFFFFFFF
    if len(packet) < 24 + payload_bytes:
        raise ValueError(f"RFRESP2 payload is truncated: expected {payload_bytes} bytes")
    return {
        "version": hdr0 & 0xFFFF,
        "status": (hdr0 >> 16) & 0xFFFF,
        "opcode": (hdr0 >> 32) & 0xFFFFFFFF,
        "seq": hdr1 & 0xFFFFFFFF,
        "payload_bytes": payload_bytes,
        "payload": packet[24:24 + payload_bytes],
    }


def parse_rfctrl2_status_payload(response: dict) -> dict:
    """Decode HELLO/STATUS capability data while tolerating old bitstreams."""
    payload = bytes(response.get("payload", b""))
    result = dict(response)
    result.update({
        "capabilities": 0,
        "state_flags": 0,
        "config_valid_mask": 0,
        "last_revision": 0,
        "last_error": 0,
        "last_error_stage": 0,
        "last_error_addr": 0,
    })
    if len(payload) >= 32:
        (
            result["capabilities"],
            result["state_flags"],
            result["config_valid_mask"],
            result["last_revision"],
            result["last_error"],
            result["last_error_stage"],
            result["last_error_addr"],
            _reserved,
        ) = struct.unpack_from("<IIIIIIII", payload)
    result["rfdc_ready"] = bool(result["state_flags"] & RF2_STATUS_RFDC_READY)
    result["rfdc_busy"] = bool(result["state_flags"] & RF2_STATUS_RFDC_BUSY)
    result["armed"] = bool(result["state_flags"] & RF2_STATUS_ARMED)
    result["running"] = bool(result["state_flags"] & RF2_STATUS_RUNNING)
    return result


def parse_rfctrl2_rfdc_config_response(response: dict) -> dict:
    """Decode a hardware-confirmed RFDC_APPLY/RFDC_GET_CONFIG response."""
    payload = bytes(response.get("payload", b""))
    result = dict(response)
    result.update({
        "revision": 0,
        "applied_mask": 0,
        "error_mask": 0,
        "config_valid_mask": 0,
        "failure_stage": 0,
        "failure_address": 0,
        "axi_response": 0,
        "state_flags": 0,
        "channels": [],
    })
    # Unsupported old bitstreams are allowed to return only the RFRESP2 header.
    if not payload and int(result.get("status", RF2_STATUS_BAD_REQUEST)) != RF2_STATUS_OK:
        return result
    expected = RFDC_APPLY_RESPONSE_HEADER_BYTES + RFDC_APPLY_CHANNELS * RFDC_APPLY_RESPONSE_ENTRY_BYTES
    if len(payload) != expected:
        raise ValueError(f"RFDC response payload must be {expected} bytes, got {len(payload)}")
    (
        result["revision"],
        result["applied_mask"],
        result["error_mask"],
        result["config_valid_mask"],
        result["failure_stage"],
        result["failure_address"],
        result["axi_response"],
        result["state_flags"],
    ) = struct.unpack_from("<IIIIIIII", payload)
    offset = RFDC_APPLY_RESPONSE_HEADER_BYTES
    for channel in range(1, RFDC_APPLY_CHANNELS + 1):
        nco_hz, zone, phase_mdeg, current_ua, channel_status, nco_word, phase_word, vop_code = struct.unpack_from(
            "<qIiIIQII", payload, offset
        )
        result["channels"].append({
            "channel": channel,
            "nco_hz": nco_hz,
            "nyquist_zone": zone,
            "nco_phase_mdeg": phase_mdeg,
            "nco_phase_deg": phase_mdeg / 1000.0,
            "dac_output_current_ua": current_ua,
            "dac_output_current_ma": current_ua / 1000.0,
            "status": channel_status,
            "nco_word": nco_word,
            "phase_word": phase_word,
            "vop_code": vop_code,
        })
        offset += RFDC_APPLY_RESPONSE_ENTRY_BYTES
    return result


def align_bytes_to_beat(n_bytes: int) -> int:
    n_bytes = int(n_bytes)
    if n_bytes < 0:
        raise ValueError("byte length must be non-negative")
    return n_bytes if n_bytes % BEAT_BYTES == 0 else n_bytes + (BEAT_BYTES - (n_bytes % BEAT_BYTES))


def require_beat_aligned(value: int, name: str) -> int:
    value = int(value)
    if value % BEAT_BYTES != 0:
        raise ValueError(f"{name} must be {BEAT_BYTES}B aligned, got 0x{value:X}")
    return value


def _normalize_waveform_int16(data_int16: np.ndarray, sample_count: int = NUM_SAMPLES) -> np.ndarray:
    """把 int16 波形裁剪/补零到 sample_count 个样本（供 GUI/工具子系统使用）。"""
    if data_int16.dtype != np.int16:
        data_int16 = data_int16.astype(np.int16)
    if len(data_int16) >= sample_count:
        return data_int16[:sample_count]
    pad = np.zeros(sample_count - len(data_int16), dtype=np.int16)
    return np.concatenate([data_int16, pad])


def iter_udp_waveform_packets(wave_bytes: bytes | np.ndarray, ddr_addr: int, sample_count: int | None = None):
    """把任意长度的波形字节流切成 32B 一组，封装成 UDP DDR 写包。

    每包：[magic(u64), ddr_addr(u64), data0..data3(u64)] 小端。
    网口写 DDR 的包粒度和播放缓冲的 256-bit / 32B DAC beat 对齐。"""
    if isinstance(wave_bytes, np.ndarray):
        samples = _normalize_waveform_int16(wave_bytes, sample_count=sample_count or len(wave_bytes))
        payload_bytes = np.ascontiguousarray(samples, dtype="<i2").tobytes()
    else:
        payload_bytes = wave_bytes
    if len(payload_bytes) % BEAT_BYTES != 0:
        payload_bytes += b"\x00" * (BEAT_BYTES - (len(payload_bytes) % BEAT_BYTES))

    base_addr = require_beat_aligned(ddr_addr, "ddr_addr") & 0xFFFFFFFFFFFFFFFF
    for offset in range(0, len(payload_bytes), BEAT_BYTES):
        data_words = struct.unpack("<QQQQ", payload_bytes[offset:offset + BEAT_BYTES])
        yield struct.pack("<QQQQQQ", UDP_WAVE_DDR_MAGIC, base_addr + offset, *data_words)


def tiled_ddr_addr(channel: int, byte_offset: int, base_addr: int = DDR_BASE) -> int:
    """Map a channel-local byte offset into the tiled 8-channel DDR layout."""
    channel_index = int(channel) - 1
    if channel_index < 0 or channel_index >= DDR_TILE_CHANNELS:
        raise ValueError("channel must be in 1..8")
    if int(byte_offset) < 0:
        raise ValueError("byte_offset must be non-negative")
    require_beat_aligned(base_addr, "base_addr")
    require_beat_aligned(byte_offset, "byte_offset")
    tile_index = int(byte_offset) // DDR_TILE_BYTES
    intra_tile_offset = int(byte_offset) % DDR_TILE_BYTES
    return int(base_addr) + tile_index * DDR_SUPERBLOCK_BYTES + channel_index * DDR_TILE_BYTES + intra_tile_offset


def tiled_channel_base_addr(channel: int, base_addr: int = DDR_BASE) -> int:
    return tiled_ddr_addr(channel, 0, base_addr=base_addr)


def interleaved_ddr_addr(channel: int, byte_offset: int, base_addr: int = DDR_BASE) -> int:
    """Map a channel-local byte offset into the 512-bit interleaved DDR layout."""
    channel_index = int(channel) - 1
    if channel_index < 0 or channel_index >= DDR_TILE_CHANNELS:
        raise ValueError("channel must be in 1..8")
    if int(byte_offset) < 0:
        raise ValueError("byte_offset must be non-negative")
    require_beat_aligned(base_addr, "base_addr")
    if int(byte_offset) % 8 != 0:
        raise ValueError("byte_offset must be 8B aligned for the interleaved layout")
    beat_index = int(byte_offset) // 8
    return int(base_addr) + beat_index * 64 + channel_index * 8


def interleaved_channel_lane_addr(channel: int, base_addr: int = DDR_BASE) -> int:
    return interleaved_ddr_addr(channel, 0, base_addr=base_addr)


def iter_tiled_udp_waveform_packets(
    wave_bytes: bytes | np.ndarray,
    channel: int,
    base_addr: int = DDR_BASE,
    sample_count: int | None = None,
):
    """Yield 32B UDP DDR writes for one logical channel in tiled DDR layout."""
    if isinstance(wave_bytes, np.ndarray):
        samples = _normalize_waveform_int16(wave_bytes, sample_count=sample_count or len(wave_bytes))
        payload_bytes = np.ascontiguousarray(samples, dtype="<i2").tobytes()
    else:
        payload_bytes = wave_bytes
    if len(payload_bytes) % BEAT_BYTES != 0:
        payload_bytes += b"\x00" * (BEAT_BYTES - (len(payload_bytes) % BEAT_BYTES))

    for offset in range(0, len(payload_bytes), BEAT_BYTES):
        data_words = struct.unpack("<QQQQ", payload_bytes[offset:offset + BEAT_BYTES])
        yield struct.pack("<QQQQQQ", UDP_WAVE_DDR_MAGIC, tiled_ddr_addr(channel, offset, base_addr=base_addr), *data_words)


def pack_interleaved_512b_waveforms(channel_waves: dict[int, np.ndarray]) -> tuple[bytes, int]:
    """Pack 8 channel-local int16 waveforms into a 512-bit interleaved DDR image."""
    if not channel_waves:
        return b"", 0
    normalized: dict[int, np.ndarray] = {}
    max_samples = 0
    for channel in range(1, DDR_TILE_CHANNELS + 1):
        wave = channel_waves.get(channel)
        if wave is None:
            normalized[channel] = np.zeros(0, dtype=np.int16)
            continue
        arr = np.asarray(wave, dtype=np.int16).reshape(-1)
        normalized[channel] = arr
        if arr.size > max_samples:
            max_samples = arr.size

    if max_samples % 16 != 0:
        max_samples += 16 - (max_samples % 16)

    packed_channels: dict[int, bytes] = {}
    for channel in range(1, DDR_TILE_CHANNELS + 1):
        wave = normalized[channel]
        if wave.size < max_samples:
            wave = np.pad(wave, (0, max_samples - wave.size), mode="constant")
        elif wave.size > max_samples:
            wave = wave[:max_samples]
        packed_channels[channel] = np.ascontiguousarray(wave, dtype="<i2").tobytes()

    beat_count = max_samples // 4
    image = bytearray(beat_count * 64)
    for beat_index in range(beat_count):
        beat_base = beat_index * 64
        lane_base = beat_index * 8
        for channel in range(1, DDR_TILE_CHANNELS + 1):
            lane = packed_channels[channel][lane_base:lane_base + 8]
            image[beat_base + (channel - 1) * 8: beat_base + channel * 8] = lane
    return bytes(image), max_samples


def iter_interleaved_udp_waveform_packets(
    channel_waves: dict[int, np.ndarray],
    base_addr: int = DDR_BASE,
):
    payload_bytes, _ = pack_interleaved_512b_waveforms(channel_waves)
    if len(payload_bytes) % BEAT_BYTES != 0:
        raise ValueError("interleaved DDR payload must still be 32B packet aligned")
    for offset in range(0, len(payload_bytes), BEAT_BYTES):
        data_words = struct.unpack("<QQQQ", payload_bytes[offset:offset + BEAT_BYTES])
        yield struct.pack("<QQQQQQ", UDP_WAVE_DDR_MAGIC, base_addr + offset, *data_words)


def max_length_marker_amplitude(channel: int, region: str) -> int:
    """Return a unique, low-amplitude CW code for one channel/marker region."""
    if channel < 1 or channel > DDR_INTERLEAVED_CHANNELS:
        raise ValueError("channel must be in 1..8")
    region_bases = {
        "body": 0x0800,
        "start": 0x1000,
        "middle": 0x2000,
        "end": 0x3000,
    }
    if region not in region_bases:
        raise ValueError(f"unsupported marker region: {region}")
    return region_bases[region] + channel * 0x80


def max_length_marker_region(
    physical_offset: int,
    total_physical_bytes: int,
    marker_bytes_per_channel: int = 4096,
) -> str:
    marker_physical_bytes = marker_bytes_per_channel * DDR_INTERLEAVED_CHANNELS
    middle_start = max(0, (total_physical_bytes // 2) - (marker_physical_bytes // 2))
    if physical_offset < marker_physical_bytes:
        return "start"
    if middle_start <= physical_offset < middle_start + marker_physical_bytes:
        return "middle"
    if physical_offset >= total_physical_bytes - marker_physical_bytes:
        return "end"
    return "body"


def max_length_interleaved_beat(
    beat_index: int,
    total_beats: int,
    marker_bytes_per_channel: int = 4096,
) -> bytes:
    """Build one 512-bit beat containing 8 unique DC-IQ channel lanes."""
    if beat_index < 0 or beat_index >= total_beats:
        raise ValueError("beat_index must select an existing 512-bit beat")
    total_physical_bytes = total_beats * DDR_INTERLEAVED_BEAT_BYTES
    physical_offset = beat_index * DDR_INTERLEAVED_BEAT_BYTES
    region = max_length_marker_region(
        physical_offset,
        total_physical_bytes,
        marker_bytes_per_channel=marker_bytes_per_channel,
    )
    return b"".join(
        struct.pack("<hhhh", max_length_marker_amplitude(channel, region), 0,
                    max_length_marker_amplitude(channel, region), 0)
        for channel in range(1, DDR_INTERLEAVED_CHANNELS + 1)
    )


def max_length_lowfreq_sine_payload(
    start_beat: int,
    beat_count: int,
    sine_freq_hz: float = 10.0,
    sine_amplitude: int = 0x1000,
    sample_rate_hz: float = DAC_IQ_SAMPLE_RATE_HZ,
) -> bytes:
    """Build interleaved 512-bit beats containing I-only low-frequency sine."""
    if beat_count <= 0:
        return b""
    amp = max(-32768, min(32767, int(round(sine_amplitude))))
    sample_offsets = np.arange(int(beat_count), dtype=np.float64)[:, None] * 2.0 + np.array([0.0, 1.0])
    sample_indices = float(start_beat) * 2.0 + sample_offsets
    base_angle = (2.0 * np.pi * float(sine_freq_hz) / float(sample_rate_hz)) * sample_indices
    payload = np.zeros((int(beat_count), DDR_INTERLEAVED_CHANNELS, 4), dtype="<i2")
    for channel in range(DDR_INTERLEAVED_CHANNELS):
        phase = (2.0 * np.pi * channel) / DDR_INTERLEAVED_CHANNELS
        i_wave = np.rint(float(amp) * np.sin(base_angle + phase)).astype("<i2")
        payload[:, channel, 0] = i_wave[:, 0]
        payload[:, channel, 2] = i_wave[:, 1]
    return payload.tobytes()


def iter_max_length_payload_chunks(
    bytes_per_channel: int,
    chunk_beats: int = 8192,
    marker_bytes_per_channel: int = 4096,
    pattern: str = MAX_LENGTH_PATTERN_LOWFREQ_SINE,
    sine_freq_hz: float = 10.0,
    sine_amplitude: int = 0x1000,
):
    """Yield ``(beat_index, payload)`` chunks of raw interleaved 512-bit data."""
    bytes_per_channel = require_beat_aligned(bytes_per_channel, "bytes_per_channel")
    if bytes_per_channel <= 0 or bytes_per_channel > DDR_MAX_BYTES_PER_CHANNEL:
        raise ValueError(
            f"bytes_per_channel must be in [32, {DDR_MAX_BYTES_PER_CHANNEL}], got {bytes_per_channel}"
        )
    if chunk_beats <= 0:
        raise ValueError("chunk_beats must be positive")
    if marker_bytes_per_channel <= 0 or marker_bytes_per_channel % BEAT_BYTES != 0:
        raise ValueError("marker_bytes_per_channel must be a positive 32B multiple")
    if pattern not in {MAX_LENGTH_PATTERN_CW_MARKER, MAX_LENGTH_PATTERN_LOWFREQ_SINE}:
        raise ValueError(f"unsupported max-length pattern: {pattern}")

    total_physical_bytes = bytes_per_channel * DDR_INTERLEAVED_CHANNELS
    total_beats = total_physical_bytes // DDR_INTERLEAVED_BEAT_BYTES
    beat_index = 0
    while beat_index < total_beats:
        count = min(chunk_beats, total_beats - beat_index)
        if pattern == MAX_LENGTH_PATTERN_CW_MARKER:
            region = max_length_marker_region(
                beat_index * DDR_INTERLEAVED_BEAT_BYTES,
                total_physical_bytes,
                marker_bytes_per_channel=marker_bytes_per_channel,
            )
            while count > 1:
                end_region = max_length_marker_region(
                    (beat_index + count - 1) * DDR_INTERLEAVED_BEAT_BYTES,
                    total_physical_bytes,
                    marker_bytes_per_channel=marker_bytes_per_channel,
                )
                if end_region == region:
                    break
                count -= 1
            beat = max_length_interleaved_beat(
                beat_index,
                total_beats,
                marker_bytes_per_channel=marker_bytes_per_channel,
            )
            payload = beat * count
        else:
            payload = max_length_lowfreq_sine_payload(
                beat_index,
                count,
                sine_freq_hz=sine_freq_hz,
                sine_amplitude=sine_amplitude,
            )
        yield beat_index, payload
        beat_index += count


def max_length_waveform_cache_key(
    bytes_per_channel: int,
    marker_bytes_per_channel: int = 4096,
    pattern: str = MAX_LENGTH_PATTERN_LOWFREQ_SINE,
    sine_freq_hz: float = 10.0,
    sine_amplitude: int = 0x1000,
) -> str:
    params = {
        "axis_hz": DAC_AXIS_HZ,
        "bytes_per_channel": int(bytes_per_channel),
        "channels": DDR_INTERLEAVED_CHANNELS,
        "lane_bytes": DDR_INTERLEAVED_LANE_BYTES,
        "marker_bytes_per_channel": int(marker_bytes_per_channel),
        "pattern": pattern,
        "sample_rate_hz": DAC_IQ_SAMPLE_RATE_HZ,
        "sine_amplitude": int(sine_amplitude),
        "sine_freq_hz": float(sine_freq_hz),
    }
    encoded = json.dumps(params, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()[:16]


def max_length_waveform_cache_path(
    cache_dir: str | Path,
    bytes_per_channel: int,
    marker_bytes_per_channel: int = 4096,
    pattern: str = MAX_LENGTH_PATTERN_LOWFREQ_SINE,
    sine_freq_hz: float = 10.0,
    sine_amplitude: int = 0x1000,
) -> Path:
    key = max_length_waveform_cache_key(
        bytes_per_channel,
        marker_bytes_per_channel=marker_bytes_per_channel,
        pattern=pattern,
        sine_freq_hz=sine_freq_hz,
        sine_amplitude=sine_amplitude,
    )
    safe_pattern = pattern.replace("-", "_")
    return Path(cache_dir).expanduser() / (
        f"max_length_{safe_pattern}_{int(bytes_per_channel)}B_ch_"
        f"{float(sine_freq_hz):.9g}Hz_{int(sine_amplitude)}_{key}.bin"
    )


def ensure_max_length_waveform_cache(
    cache_dir: str | Path,
    bytes_per_channel: int,
    marker_bytes_per_channel: int = 4096,
    pattern: str = MAX_LENGTH_PATTERN_LOWFREQ_SINE,
    sine_freq_hz: float = 10.0,
    sine_amplitude: int = 0x1000,
    force: bool = False,
    generation_chunk_beats: int = 8192,
) -> Path:
    """Generate or reuse a raw interleaved max-length payload cache file."""
    bytes_per_channel = require_beat_aligned(int(bytes_per_channel), "bytes_per_channel")
    expected_size = bytes_per_channel * DDR_INTERLEAVED_CHANNELS
    cache_path = max_length_waveform_cache_path(
        cache_dir,
        bytes_per_channel,
        marker_bytes_per_channel=marker_bytes_per_channel,
        pattern=pattern,
        sine_freq_hz=sine_freq_hz,
        sine_amplitude=sine_amplitude,
    )
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    if cache_path.exists() and cache_path.stat().st_size == expected_size and not force:
        return cache_path

    tmp_path = cache_path.with_name(f".{cache_path.name}.tmp.{os.getpid()}")
    if tmp_path.exists():
        tmp_path.unlink()
    written = 0
    start_time = time.monotonic()
    with tmp_path.open("wb") as f:
        for _beat_index, payload in iter_max_length_payload_chunks(
            bytes_per_channel,
            chunk_beats=int(generation_chunk_beats),
            marker_bytes_per_channel=marker_bytes_per_channel,
            pattern=pattern,
            sine_freq_hz=sine_freq_hz,
            sine_amplitude=sine_amplitude,
        ):
            f.write(payload)
            written += len(payload)
    if written != expected_size:
        tmp_path.unlink(missing_ok=True)
        raise RuntimeError(f"cache generation wrote {written} bytes, expected {expected_size}")
    tmp_path.replace(cache_path)
    metadata = {
        "bytes_per_channel": bytes_per_channel,
        "created_unix_s": time.time(),
        "generation_elapsed_s": time.monotonic() - start_time,
        "marker_bytes_per_channel": int(marker_bytes_per_channel),
        "pattern": pattern,
        "physical_ddr_bytes": expected_size,
        "sine_amplitude": int(sine_amplitude),
        "sine_freq_hz": float(sine_freq_hz),
    }
    cache_path.with_suffix(cache_path.suffix + ".json").write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return cache_path


def iter_max_length_udp_batches(
    bytes_per_channel: int,
    base_addr: int = DDR_BASE,
    beats_per_datagram: int = 128,
    marker_bytes_per_channel: int = 4096,
    pattern: str = MAX_LENGTH_PATTERN_LOWFREQ_SINE,
    sine_freq_hz: float = 10.0,
    sine_amplitude: int = 0x1000,
):
    """Yield bulk UDP datagrams for a large deterministic interleaved record.

    Each datagram contains a 24-byte bulk header followed by consecutive
    512-bit DDR beats. The board writer converts each four 64-bit data words
    into one 32-byte AXI write and increments the address automatically.
    """
    base_addr = require_beat_aligned(base_addr, "base_addr")
    if beats_per_datagram <= 0 or 24 + beats_per_datagram * DDR_INTERLEAVED_BEAT_BYTES > 9216:
        raise ValueError("beats_per_datagram must produce a UDP payload no larger than 9216 bytes")
    for beat_index, payload in iter_max_length_payload_chunks(
        bytes_per_channel,
        chunk_beats=beats_per_datagram,
        marker_bytes_per_channel=marker_bytes_per_channel,
        pattern=pattern,
        sine_freq_hz=sine_freq_hz,
        sine_amplitude=sine_amplitude,
    ):
        yield struct.pack(
            "<QQQ",
            UDP_WAVE_BULK_MAGIC,
            base_addr + beat_index * DDR_INTERLEAVED_BEAT_BYTES,
            len(payload) // 8,
        ) + payload


def iter_max_length_udp_batches_from_cache(
    cache_path: str | Path,
    bytes_per_channel: int,
    base_addr: int = DDR_BASE,
    beats_per_datagram: int = 128,
):
    bytes_per_channel = require_beat_aligned(int(bytes_per_channel), "bytes_per_channel")
    base_addr = require_beat_aligned(base_addr, "base_addr")
    if beats_per_datagram <= 0 or 24 + beats_per_datagram * DDR_INTERLEAVED_BEAT_BYTES > 9216:
        raise ValueError("beats_per_datagram must produce a UDP payload no larger than 9216 bytes")
    expected_size = bytes_per_channel * DDR_INTERLEAVED_CHANNELS
    path = Path(cache_path).expanduser()
    if path.stat().st_size != expected_size:
        raise ValueError(f"cache file size {path.stat().st_size} does not match expected {expected_size}")
    chunk_bytes = beats_per_datagram * DDR_INTERLEAVED_BEAT_BYTES
    beat_index = 0
    read_bytes = 0
    with path.open("rb") as f:
        while read_bytes < expected_size:
            payload = f.read(min(chunk_bytes, expected_size - read_bytes))
            if not payload:
                break
            if len(payload) % DDR_INTERLEAVED_BEAT_BYTES != 0:
                raise ValueError("cache chunk is not 512-bit beat aligned")
            yield struct.pack(
                "<QQQ",
                UDP_WAVE_BULK_MAGIC,
                base_addr + beat_index * DDR_INTERLEAVED_BEAT_BYTES,
                len(payload) // 8,
            ) + payload
            beats = len(payload) // DDR_INTERLEAVED_BEAT_BYTES
            beat_index += beats
            read_bytes += len(payload)
    if read_bytes != expected_size:
        raise RuntimeError(f"cache read {read_bytes} bytes, expected {expected_size}")


def decode_udp_waveform_packet(packet: bytes) -> tuple[int, int, bytes]:
    """Decode one board-facing UDP DDR write packet for tests/ILA correlation."""
    if len(packet) != 48:
        raise ValueError(f"UDP DDR write packet must be 48 bytes, got {len(packet)}")
    magic, ddr_addr, word0, word1, word2, word3 = struct.unpack("<QQQQQQ", packet)
    if magic != UDP_WAVE_DDR_MAGIC:
        raise ValueError(f"bad UDP DDR magic 0x{magic:016X}")
    require_beat_aligned(ddr_addr, "ddr_addr")
    return magic, ddr_addr, struct.pack("<QQQQ", word0, word1, word2, word3)


def decode_udp_bulk_datagram(datagram: bytes) -> tuple[int, bytes]:
    if len(datagram) < 24:
        raise ValueError("bulk UDP datagram must contain a 24-byte header")
    magic, ddr_addr, word_count = struct.unpack("<QQQ", datagram[:24])
    if magic != UDP_WAVE_BULK_MAGIC:
        raise ValueError(f"bad bulk UDP magic 0x{magic:016X}")
    require_beat_aligned(ddr_addr, "ddr_addr")
    payload = datagram[24:]
    if word_count == 0 or word_count % 4 != 0 or len(payload) != word_count * 8:
        raise ValueError("bulk UDP word_count does not match the aligned payload")
    return ddr_addr, payload


# ============================================================
# 2. 波形生成（DC 复基带，单频 CW）
# ============================================================
def build_dc_iq_tone(n_bytes: int, amp: float = TONE_AMP) -> np.ndarray:
    """生成一段 DC IQ DDR 缓冲。

    n_bytes 必须为 32 的倍数（一个 256-bit DAC 字 = 32B）。
    返回 int16 数组（小端写入 DDR），偶数 lane 是常数 I，奇数 lane 是 Q=0。
    经 NCO 上变频后等价于 DC 复基带 -> 单一 NCO 频率的 CW。"""
    if n_bytes % 32 != 0:
        n_bytes += 32 - (n_bytes % 32)
    c = int(round(float(amp) * 32767))
    c = max(-32768, min(32767, c))
    n_samples = n_bytes // 2
    wave = np.zeros(n_samples, dtype=np.int16)
    wave[0::2] = c
    return wave


# ============================================================
# 3. 发送控制
# ============================================================
class RFSocController:
    def __init__(self, ip, port=1234, timeout_s=5.0, transport="udp", udp_interface="", udp_source_ip=""):
        self.ip = ip
        self.port = port
        self.transport = transport
        sock_type = socket.SOCK_DGRAM if transport == "udp" else socket.SOCK_STREAM
        self.sock = socket.socket(socket.AF_INET, sock_type)
        self.sock.settimeout(timeout_s)
        if transport == "udp" and udp_interface:
            self.sock.setsockopt(socket.SOL_SOCKET, SO_BINDTODEVICE, udp_interface.encode("ascii") + b"\0")
        if transport == "udp" and udp_source_ip:
            self.sock.bind((udp_source_ip, 0))
        if transport == "tcp":
            self.sock.connect((ip, port))
        self._rfdc_mailbox_seq = int(time.time() * 1000.0) & 0xFFFFFFFF

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass

    def _send_packet(self, p_type, data: bytes):
        """发送 [Type(u32), Len(u32), Data] 小端"""
        header = struct.pack("<II", p_type, len(data))
        packet = header + data
        if self.transport == "udp":
            return self.sock.sendto(packet, (self.ip, self.port))
        self.sock.sendall(packet)
        return self.sock.recv(1024)  # 等待 ACK

    def send_udp_words(self, payload: bytes):
        if len(payload) % 8 != 0:
            payload += b"\x00" * (8 - (len(payload) % 8))
        print(f"[udp] Sending {len(payload)} bytes ({len(payload) // 8} x 64-bit words) to {self.ip}:{self.port}")
        return self.sock.sendto(payload, (self.ip, self.port))

    def send_rvctrl_words(self, words32: list[int] | tuple[int, ...]):
        packet = pack_rvctrl_packet(words32)
        print(f"[rvctrl] Sending {len(words32)} x 32-bit control words to {self.ip}:{self.port}")
        return self.sock.sendto(packet, (self.ip, self.port))

    def rvctrl_ping(self, seq: int = 1):
        print(f"[rvctrl] PING seq={int(seq) & 0xFFFFFFFF}")
        return self.sock.sendto(pack_rvctrl_ping(seq), (self.ip, self.port))

    def rvctrl_play_interleaved(
        self,
        bytes_per_channel: int,
        seq: int = 1,
        auto_start: bool = True,
        loop: bool = False,
    ):
        print(
            f"[rvctrl] PLAY_INTERLEAVED seq={int(seq) & 0xFFFFFFFF}, "
            f"bytes_per_channel={int(bytes_per_channel)}, auto_start={auto_start}, loop={loop}"
        )
        return self.sock.sendto(
            pack_rvctrl_play_interleaved(bytes_per_channel, seq=seq, auto_start=auto_start, loop=loop),
            (self.ip, self.port),
        )

    def rvctrl_trigger(self, seq: int = 1):
        print(f"[rvctrl] TRIGGER seq={int(seq) & 0xFFFFFFFF}")
        return self.sock.sendto(pack_rvctrl_trigger(seq), (self.ip, self.port))

    def rvctrl_write_mmio(self, addr: int, value: int, seq: int = 1):
        print(
            f"[rvctrl] WRITE_MMIO seq={int(seq) & 0xFFFFFFFF}, "
            f"addr=0x{int(addr) & 0xFFFFFFFF:08X}, value=0x{int(value) & 0xFFFFFFFF:08X}"
        )
        return self.sock.sendto(pack_rvctrl_write_mmio(addr, value, seq=seq), (self.ip, self.port))

    def send_rvctrl1_packet(self, opcode: int, payload: bytes = b"", seq: int = 1, flags: int = 0):
        packet = pack_rvctrl1_packet(opcode, payload=payload, seq=seq, flags=flags)
        print(
            f"[rvctrl1] opcode=0x{int(opcode) & 0xFFFFFFFF:08X}, "
            f"seq={int(seq) & 0xFFFFFFFF}, payload={len(payload)} bytes"
        )
        return self.sock.sendto(packet, (self.ip, self.port))

    def recv_rvresp1(self, expected_seq: int | None = None, expected_opcode: int | None = None):
        while True:
            packet, addr = self.sock.recvfrom(2048)
            resp = parse_rvresp1_packet(packet)
            if expected_seq is not None and resp["seq"] != (int(expected_seq) & 0xFFFFFFFF):
                print(f"[rvresp1] skip seq={resp['seq']} from {addr}")
                continue
            if expected_opcode is not None and resp["opcode"] != (int(expected_opcode) & 0xFFFFFFFF):
                print(f"[rvresp1] skip opcode=0x{resp['opcode']:08X} from {addr}")
                continue
            resp["addr"] = addr
            return resp

    def _send_rvctrl1_and_maybe_recv(self, packet: bytes, opcode: int, seq: int, wait_response: bool):
        sent = self.sock.sendto(packet, (self.ip, self.port))
        if not wait_response:
            return sent
        return self.recv_rvresp1(expected_seq=seq, expected_opcode=opcode)

    def rvctrl1_ping(self, seq: int = 1, wait_response: bool = False):
        print(f"[rvctrl1] PING seq={int(seq) & 0xFFFFFFFF}")
        return self._send_rvctrl1_and_maybe_recv(pack_rvctrl1_ping(seq), RV1_OP_PING, seq, wait_response)

    def rvctrl1_mmio_read32(self, addr: int, seq: int = 1, wait_response: bool = False):
        print(f"[rvctrl1] MMIO_READ32 seq={int(seq) & 0xFFFFFFFF}, addr=0x{int(addr) & 0xFFFFFFFF:08X}")
        return self._send_rvctrl1_and_maybe_recv(
            pack_rvctrl1_mmio_read32(addr, seq=seq),
            RV1_OP_MMIO_READ32,
            seq,
            wait_response,
        )

    def rvctrl1_mmio_write32(self, addr: int, value: int, seq: int = 1, wait_response: bool = False):
        print(
            f"[rvctrl1] MMIO_WRITE32 seq={int(seq) & 0xFFFFFFFF}, "
            f"addr=0x{int(addr) & 0xFFFFFFFF:08X}, value=0x{int(value) & 0xFFFFFFFF:08X}"
        )
        return self._send_rvctrl1_and_maybe_recv(
            pack_rvctrl1_mmio_write32(addr, value, seq=seq),
            RV1_OP_MMIO_WRITE32,
            seq,
            wait_response,
        )

    def rvctrl1_mmio_rmw32(self, addr: int, mask: int, value: int, seq: int = 1, wait_response: bool = False):
        print(
            f"[rvctrl1] MMIO_RMW32 seq={int(seq) & 0xFFFFFFFF}, "
            f"addr=0x{int(addr) & 0xFFFFFFFF:08X}, mask=0x{int(mask) & 0xFFFFFFFF:08X}, "
            f"value=0x{int(value) & 0xFFFFFFFF:08X}"
        )
        return self._send_rvctrl1_and_maybe_recv(
            pack_rvctrl1_mmio_rmw32(addr, mask, value, seq=seq),
            RV1_OP_MMIO_RMW32,
            seq,
            wait_response,
        )

    def rvctrl1_mmio_batch(
        self,
        writes: list[tuple[int, int]] | tuple[tuple[int, int], ...],
        seq: int = 1,
        wait_response: bool = False,
    ):
        print(f"[rvctrl1] MMIO_BATCH seq={int(seq) & 0xFFFFFFFF}, writes={len(writes)}")
        return self._send_rvctrl1_and_maybe_recv(
            pack_rvctrl1_mmio_batch(writes, seq=seq),
            RV1_OP_MMIO_BATCH,
            seq,
            wait_response,
        )

    def rvctrl1_play_interleaved(
        self,
        bytes_per_channel: int,
        seq: int = 1,
        auto_start: bool = True,
        loop: bool = False,
        wait_response: bool = False,
    ):
        print(
            f"[rvctrl1] PLAY_INTERLEAVED seq={int(seq) & 0xFFFFFFFF}, "
            f"bytes_per_channel={int(bytes_per_channel)}, auto_start={auto_start}, loop={loop}"
        )
        return self._send_rvctrl1_and_maybe_recv(
            pack_rvctrl1_play_interleaved(bytes_per_channel, seq=seq, auto_start=auto_start, loop=loop),
            RV1_OP_PLAY_INTERLEAVED,
            seq,
            wait_response,
        )

    def rvctrl1_trigger(self, seq: int = 1, wait_response: bool = False):
        print(f"[rvctrl1] TRIGGER seq={int(seq) & 0xFFFFFFFF}")
        return self._send_rvctrl1_and_maybe_recv(pack_rvctrl1_trigger(seq), RV1_OP_TRIGGER, seq, wait_response)

    def rvctrl1_rfdc_ch_enable(
        self,
        channel_mask: int,
        enable_mask: int,
        seq: int = 1,
        wait_response: bool = False,
    ):
        print(
            f"[rvctrl1] RFDC_CH_ENABLE seq={int(seq) & 0xFFFFFFFF}, "
            f"channel_mask=0x{int(channel_mask) & 0xFF:02X}, enable_mask=0x{int(enable_mask) & 0xFF:02X}"
        )
        return self._send_rvctrl1_and_maybe_recv(
            pack_rvctrl1_rfdc_ch_enable(channel_mask, enable_mask, seq=seq),
            RV1_OP_RFDC_CH_ENABLE,
            seq,
            wait_response,
        )

    def rvctrl1_status_read(self, seq: int = 1, wait_response: bool = True):
        print(f"[rvctrl1] STATUS_READ seq={int(seq) & 0xFFFFFFFF}")
        return self._send_rvctrl1_and_maybe_recv(
            pack_rvctrl1_status_read(seq=seq),
            RV1_OP_STATUS_READ,
            seq,
            wait_response,
        )

    def rvctrl1_rfdc_set_nco(self, nco_hz, nyquist_zones, seq: int = 1, apply_mask: int = 0xFF, wait_response: bool = False):
        print(f"[rvctrl1] RFDC_SET_NCO seq={int(seq) & 0xFFFFFFFF}, apply_mask=0x{int(apply_mask) & 0xFF:02X}")
        return self._send_rvctrl1_and_maybe_recv(
            pack_rvctrl1_rfdc_set_nco(nco_hz, nyquist_zones, seq=seq, apply_mask=apply_mask),
            RV1_OP_RFDC_SET_NCO,
            seq,
            wait_response,
        )

    def recv_rfresp2(self, expected_seq: int | None = None, expected_opcode: int | None = None):
        while True:
            packet, addr = self.sock.recvfrom(2048)
            response = parse_rfresp2_packet(packet)
            if expected_seq is not None and response["seq"] != (int(expected_seq) & 0xFFFFFFFF):
                continue
            if expected_opcode is not None and response["opcode"] != (int(expected_opcode) & 0xFFFFFFFF):
                continue
            response["addr"] = addr
            return response

    def _send_rfctrl2(
        self,
        packet: bytes,
        opcode: int,
        seq: int,
        wait_response: bool,
        retries: int = 0,
    ):
        """Send one immutable request, retrying with the same sequence number."""
        attempts = max(0, int(retries)) + 1
        for attempt in range(attempts):
            sent = self.sock.sendto(packet, (self.ip, self.port))
            if not wait_response:
                return sent
            try:
                return self.recv_rfresp2(expected_seq=seq, expected_opcode=opcode)
            except socket.timeout:
                if attempt + 1 >= attempts:
                    raise
        raise AssertionError("unreachable RFCTRL2 retry state")

    def rfctrl2_hello(self, seq: int = 1, wait_response: bool = True):
        return self._send_rfctrl2(pack_rfctrl2_hello(seq), RF2_OP_HELLO, seq, wait_response)

    def rfctrl2_status(self, seq: int = 1, wait_response: bool = True):
        return self._send_rfctrl2(pack_rfctrl2_status(seq), RF2_OP_STATUS, seq, wait_response)

    def rfctrl2_rfdc_apply(
        self,
        per_channel_nco_hz,
        per_channel_nyquist_zone,
        per_channel_phase_deg,
        per_channel_output_current_ma,
        revision: int,
        channel_mask: int = 0xFF,
        seq: int = 1,
        wait_response: bool = True,
        retries: int = 2,
    ):
        packet = pack_rfctrl2_rfdc_apply(
            per_channel_nco_hz,
            per_channel_nyquist_zone,
            per_channel_phase_deg,
            per_channel_output_current_ma,
            revision=revision,
            channel_mask=channel_mask,
            seq=seq,
        )
        response = self._send_rfctrl2(
            packet, RF2_OP_RFDC_APPLY, seq, wait_response, retries=retries
        )
        return parse_rfctrl2_rfdc_config_response(response) if wait_response else response

    def rfctrl2_rfdc_get_config(
        self,
        seq: int = 1,
        wait_response: bool = True,
        retries: int = 2,
    ):
        response = self._send_rfctrl2(
            pack_rfctrl2_rfdc_get_config(seq),
            RF2_OP_RFDC_GET_CONFIG,
            seq,
            wait_response,
            retries=retries,
        )
        return parse_rfctrl2_rfdc_config_response(response) if wait_response else response

    def rfctrl2_arm(self, run_id: int, channel_mask: int = 0xFF, seq: int = 1, wait_response: bool = True):
        return self._send_rfctrl2(pack_rfctrl2_arm(run_id, channel_mask, seq), RF2_OP_ARM, seq, wait_response)

    def rfctrl2_sync_epoch(self, epoch: int, seq: int = 1, wait_response: bool = True):
        return self._send_rfctrl2(pack_rfctrl2_sync_epoch(epoch, seq), RF2_OP_SYNC_EPOCH, seq, wait_response)

    def rfctrl2_start_at(self, start_tick: int, seq: int = 1, wait_response: bool = True):
        return self._send_rfctrl2(pack_rfctrl2_start_at(start_tick, seq), RF2_OP_START_AT, seq, wait_response)

    def rfctrl2_trigger(self, seq: int = 1, wait_response: bool = True):
        return self._send_rfctrl2(pack_rfctrl2_trigger(seq), RF2_OP_TRIGGER, seq, wait_response)

    def rfctrl2_abort_mute(self, seq: int = 1, wait_response: bool = True):
        return self._send_rfctrl2(pack_rfctrl2_abort_mute(seq), RF2_OP_ABORT_MUTE, seq, wait_response)

    @staticmethod
    def _save_hex_text(byte_data: bytes, filepath: str, bytes_per_line: int = 16, style: str = "hexdump"):
        with open(filepath, "w", encoding="utf-8") as f:
            if style == "raw":
                for i in range(0, len(byte_data), bytes_per_line):
                    f.write(byte_data[i:i+bytes_per_line].hex() + "\n")
            elif style == "spaced":
                for i in range(0, len(byte_data), bytes_per_line):
                    chunk = byte_data[i:i+bytes_per_line]
                    f.write(" ".join(f"{b:02X}" for b in chunk) + "\n")
            elif style == "hexdump":
                for i in range(0, len(byte_data), bytes_per_line):
                    chunk = byte_data[i:i+bytes_per_line]
                    hex_part = " ".join(f"{b:02X}" for b in chunk)
                    f.write(f"{i:08X}  {hex_part}\n")
            else:
                raise ValueError(f"Unknown style: {style}")

    def upload_waveform(self, data_int16: np.ndarray, ddr_addr: int,
                        dump_path: str, dump_style: str = "hexdump"):
        """TCP 路径：type=0 payload = [uint64 ddr_addr] + [wave bytes...]"""
        wave_bytes = np.ascontiguousarray(data_int16, dtype="<i2").tobytes()
        self._save_hex_text(wave_bytes, dump_path, bytes_per_line=16, style=dump_style)
        print(f"[dump] {dump_path}  ({len(wave_bytes)} bytes)")

        payload = struct.pack("<Q", int(ddr_addr) & 0xFFFFFFFFFFFFFFFF) + wave_bytes
        print(f"[upload] addr=0x{ddr_addr:016X}, payload={len(payload)} bytes (8+{len(wave_bytes)})")
        return self._send_packet(0, payload)

    def upload_waveform_udp(self, data_int16: np.ndarray, ddr_addr: int,
                            dump_path: str, dump_style: str = "hexdump"):
        wave_bytes = np.ascontiguousarray(data_int16, dtype="<i2").tobytes()
        self._save_hex_text(wave_bytes, dump_path, bytes_per_line=16, style=dump_style)

        packet_count = 0
        for packet in iter_udp_waveform_packets(wave_bytes, ddr_addr):
            self.sock.sendto(packet, (self.ip, self.port))
            packet_count += 1
            if packet_count % 8 == 0:
                time.sleep(0.00001)

        print(f"[udp-upload] addr=0x{ddr_addr:016X}, wave={len(wave_bytes)} bytes, packets={packet_count}")
        return packet_count

    def upload_waveform_udp_tiled(self, data_int16: np.ndarray, channel: int,
                                  base_addr: int, dump_path: str,
                                  dump_style: str = "hexdump"):
        wave_bytes = np.ascontiguousarray(data_int16, dtype="<i2").tobytes()
        self._save_hex_text(wave_bytes, dump_path, bytes_per_line=16, style=dump_style)

        packet_count = 0
        for packet in iter_tiled_udp_waveform_packets(wave_bytes, channel, base_addr=base_addr):
            self.sock.sendto(packet, (self.ip, self.port))
            packet_count += 1
            if packet_count % 8 == 0:
                time.sleep(0.00001)

        first_addr = tiled_channel_base_addr(channel, base_addr=base_addr)
        print(f"[udp-upload:tiled] ch={channel}, tile0=0x{first_addr:016X}, wave={len(wave_bytes)} bytes, packets={packet_count}")
        return packet_count

    def upload_waveform_udp_interleaved(self, channel_waves: dict[int, np.ndarray],
                                        base_addr: int, dump_path: str,
                                        dump_style: str = "hexdump"):
        payload_bytes, logical_samples = pack_interleaved_512b_waveforms(channel_waves)
        self._save_hex_text(payload_bytes, dump_path, bytes_per_line=16, style=dump_style)

        packet_count = 0
        for packet in iter_interleaved_udp_waveform_packets(channel_waves, base_addr=base_addr):
            self.sock.sendto(packet, (self.ip, self.port))
            packet_count += 1
            if packet_count % 8 == 0:
                time.sleep(0.00001)

        print(
            f"[udp-upload:interleaved_512b] base=0x{base_addr:016X}, "
            f"bytes={len(payload_bytes)}, logical_samples={logical_samples}, packets={packet_count}"
        )
        return packet_count

    def upload_max_length_udp(
        self,
        bytes_per_channel: int,
        base_addr: int = DDR_BASE,
        beats_per_datagram: int = 128,
        marker_bytes_per_channel: int = 4096,
        pattern: str = MAX_LENGTH_PATTERN_LOWFREQ_SINE,
        sine_freq_hz: float = 10.0,
        sine_amplitude: int = 0x1000,
        batch_pause_s: float = 0.0,
        progress_bytes: int = 256 * 1024 * 1024,
        use_waveform_cache: bool = False,
        waveform_cache_dir: str | Path | None = None,
        force_waveform_cache: bool = False,
    ) -> int:
        total_bytes = int(bytes_per_channel) * DDR_INTERLEAVED_CHANNELS
        datagram_count = 0
        sent_bytes = 0
        next_progress = max(1, int(progress_bytes))
        start_time = time.monotonic()
        if use_waveform_cache:
            cache_path = ensure_max_length_waveform_cache(
                waveform_cache_dir or DEFAULT_WAVEFORM_CACHE_DIR,
                bytes_per_channel,
                marker_bytes_per_channel=marker_bytes_per_channel,
                pattern=pattern,
                sine_freq_hz=sine_freq_hz,
                sine_amplitude=sine_amplitude,
                force=force_waveform_cache,
            )
            print(f"[udp-upload:max-length] using waveform cache {cache_path}")
            datagrams = iter_max_length_udp_batches_from_cache(
                cache_path,
                bytes_per_channel,
                base_addr=base_addr,
                beats_per_datagram=beats_per_datagram,
            )
        else:
            datagrams = iter_max_length_udp_batches(
                bytes_per_channel,
                base_addr=base_addr,
                beats_per_datagram=beats_per_datagram,
                marker_bytes_per_channel=marker_bytes_per_channel,
                pattern=pattern,
                sine_freq_hz=sine_freq_hz,
                sine_amplitude=sine_amplitude,
            )
        for datagram in datagrams:
            self.sock.sendto(datagram, (self.ip, self.port))
            datagram_count += 1
            sent_bytes += len(datagram) - 24
            if batch_pause_s > 0:
                time.sleep(batch_pause_s)
            if sent_bytes >= next_progress or sent_bytes == total_bytes:
                elapsed = max(time.monotonic() - start_time, 1e-9)
                print(
                    f"[udp-upload:max-length] {sent_bytes}/{total_bytes} bytes "
                    f"({100.0 * sent_bytes / total_bytes:.1f}%), {sent_bytes / elapsed / 1e6:.1f} MB/s"
                )
                next_progress += max(1, int(progress_bytes))
        return datagram_count

    def upload_rfdc_nco_mailbox(
        self,
        per_channel_nco_hz: dict[int, float] | dict[str, float],
        per_channel_nyquist_zone: dict[int, int] | dict[str, int],
        apply_mask: int = 0xFF,
        flags: int = RFDC_CTRL_MAILBOX_FLAG_APPLY_IMMEDIATE,
        seq: int | None = None,
    ):
        if seq is None:
            self._rfdc_mailbox_seq = (self._rfdc_mailbox_seq + 1) & 0xFFFFFFFF
            if self._rfdc_mailbox_seq == 0:
                self._rfdc_mailbox_seq = 1
            seq = self._rfdc_mailbox_seq
        packet_count = 0
        for packet in iter_rfdc_nco_mailbox_packets(
            per_channel_nco_hz,
            per_channel_nyquist_zone,
            seq=int(seq),
            apply_mask=int(apply_mask),
            flags=int(flags),
        ):
            self.sock.sendto(packet, (self.ip, self.port))
            packet_count += 1
            if packet_count % 8 == 0:
                time.sleep(0.00001)
        print(
            f"[udp-rfdc-mailbox] offset=0x{RFDC_CTRL_MAILBOX_OFFSET:09X}, "
            f"seq={int(seq) & 0xFFFFFFFF}, apply_mask=0x{int(apply_mask) & 0xFF:02X}, packets={packet_count}"
        )
        return packet_count

    def upload_rfdc_runtime_mailbox(
        self,
        per_channel_nco_hz,
        per_channel_nyquist_zone,
        per_channel_phase_deg,
        per_channel_output_current_ma,
        seq: int,
        apply_mask: int = 0xFF,
    ):
        packet_count = 0
        for packet in iter_rfdc_runtime_mailbox_packets(
            per_channel_nco_hz, per_channel_nyquist_zone, per_channel_phase_deg,
            per_channel_output_current_ma, seq=seq, apply_mask=apply_mask,
        ):
            self.sock.sendto(packet, (self.ip, self.port))
            packet_count += 1
        return packet_count

    def upload_waveform_interleaved(self, channel_waves: dict[int, np.ndarray],
                                    ddr_addr: int, dump_path: str,
                                    dump_style: str = "hexdump"):
        payload_bytes, logical_samples = pack_interleaved_512b_waveforms(channel_waves)
        self._save_hex_text(payload_bytes, dump_path, bytes_per_line=16, style=dump_style)
        payload = struct.pack("<Q", int(ddr_addr) & 0xFFFFFFFFFFFFFFFF) + payload_bytes
        print(
            f"[upload:interleaved_512b] addr=0x{ddr_addr:016X}, "
            f"bytes={len(payload_bytes)}, logical_samples={logical_samples}"
        )
        return self._send_packet(0, payload)

    def send_instructions(self, cmd_list):
        """type=1：每条 16B：w0/w1/w2/w3"""
        bin_cmds = b""
        for cmd in cmd_list:
            # cmd=[op,ch,len_or_delay,addr] or [op,ch,len_or_delay,addr,flags]
            op = int(cmd[0]) & 0xF
            channel = int(cmd[1]) & 0xF
            flags = int(cmd[4]) if len(cmd) > 4 else 0
            if op == 2:
                require_beat_aligned(cmd[2], "PLAY length")
                require_beat_aligned(cmd[3], "PLAY addr")
            word0 = (channel << 4) | op | ((flags & 0x7) << 8)
            word1 = int(cmd[2]) & 0xFFFFFFFF
            addr = int(cmd[3]) & 0xFFFFFFFFFFFFFFFF
            word2 = addr & 0xFFFFFFFF
            word3 = (addr >> 32) & 0xFFFFFFFF
            bin_cmds += struct.pack("<IIII", word0, word1, word2, word3)

        print(f"[instr] Sending {len(cmd_list)} instructions, {len(bin_cmds)} bytes")
        if self.transport == "udp":
            return self.send_udp_words(bin_cmds)
        return self._send_packet(1, bin_cmds)

    def trigger(self):
        """Issue a playback trigger.

        The PL UDP receiver consumes raw 64-bit words, so the UDP path uses a
        single reserved word instead of the legacy type/length packet header.
        """
        if self.transport == "udp":
            print("[trig] UDP TRIGGER1")
            return self.send_udp_words(struct.pack("<Q", UDP_TRIGGER_WORD))
        print("[trig] GO")
        return self._send_packet(2, b"GO")


# ============================================================
# 4. Plot 工具
# ============================================================
def plot_tone(ch_int16, n_preview: int = 256, title_prefix: str = ""):
    plt.figure(figsize=(12, 5))
    for idx, q in enumerate(ch_int16):
        plt.plot(q[:n_preview], label=f"CH{idx + 1} int16")
    plt.title(f"{title_prefix}DC-IQ Tone Preview (first {n_preview} int16 lanes)")
    plt.xlabel("int16 lane index")
    plt.ylabel("Amplitude (int16)")
    plt.grid(True)
    plt.legend()
    plt.tight_layout()
    plt.savefig("wave_preview_firstN.png", dpi=150)
    plt.close()
    print("[plot] saved: wave_preview_firstN.png")


# ============================================================
# 5. 主程序
# ============================================================
def parse_args():
    parser = argparse.ArgumentParser(description="XCZU47DR RFSoC host controller (8-ch NCO C2R CW)")
    parser.add_argument("--ip", default=DEFAULT_BOARD_IP, help="Board IPv4 address")
    parser.add_argument("--port", type=int, default=DEFAULT_BOARD_PORT, help="Board UDP/TCP port")
    parser.add_argument("--transport", choices=("udp", "tcp"), default="udp",
                        help="Transport for instructions; UDP is the 10G PL path")
    parser.add_argument("--timeout", type=float, default=5.0, help="Socket timeout in seconds")
    parser.add_argument("--tone-bytes", type=int, default=TONE_BYTES_DEFAULT,
                        help="Per-channel DDR buffer size in bytes (32B aligned)")
    parser.add_argument("--tone-amp", type=float, default=TONE_AMP,
                        help="Per-lane amplitude as a fraction of full scale (0..1)")
    parser.add_argument("--channels", default="1,2,3,4,5,6,7,8",
                        help="Comma-separated executor channels to play (1..8 -> physical DAC slices)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Generate plots and waveform dumps without connecting to hardware")
    parser.add_argument("--output-dir", default=".", help="Directory for generated plots and dumps")
    parser.add_argument("--wait-for-trigger", action="store_true",
                        help="In UDP mode, send a normal END and wait for a PS/external trigger instead of auto-starting")
    parser.add_argument("--udp-write-settle-s", type=float, default=DEFAULT_UDP_WRITE_SETTLE_S,
                        help="Delay after UDP waveform upload before PLAY instructions, allowing DDR writes to settle")
    parser.add_argument("--udp-interface", default=DEFAULT_UDP_INTERFACE,
                        help="UDP sender interface name, e.g. enp225s0f0, to avoid wrong same-subnet routes")
    parser.add_argument("--udp-source-ip", default=DEFAULT_UDP_SOURCE_IP,
                        help="UDP source IPv4 address to bind before sending")
    parser.add_argument("--ddr-layout", choices=(DDR_LAYOUT_INTERLEAVED_512B, DDR_LAYOUT_TILED, DDR_LAYOUT_CONTIGUOUS),
                        default=DEFAULT_DDR_LAYOUT,
                        help="DDR layout for RFDC playback; interleaved_512b is the normal 8-channel streaming layout")
    return parser.parse_args()


def main():
    args = parse_args()
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    channels = sorted({int(c) for c in args.channels.split(",") if c.strip()})
    for ch in channels:
        if ch < 1 or ch > 8:
            raise SystemExit(f"channel {ch} out of range (1..8)")

    tone_bytes = int(args.tone_bytes)
    if tone_bytes % 32 != 0:
        tone_bytes += 32 - (tone_bytes % 32)

    tone = build_dc_iq_tone(tone_bytes, amp=args.tone_amp)
    print(f"[wave] DC-IQ CW, per-ch {tone_bytes} bytes "
          f"({tone_bytes // 32} x 256-bit DAC words), amp={args.tone_amp}, "
          f"const={int(tone[0])}, channels={channels}")
    print(f"[wave] fabric/AXIS clock = {DAC_FABRIC_HZ/1e6:.3f} MHz, "
          f"Fs={DAC_TILE_FS/1e9:.1f} GSPS, interp={DAC_INTERP}, NCO~{NCO_FREQ_GHZ} GHz (firmware-set)")

    old_cwd = Path.cwd()
    os.chdir(output_dir)
    try:
        plot_tone([tone for _ in channels], n_preview=256, title_prefix="Before Send: ")

        if args.dry_run:
            RFSocController._save_hex_text(
                np.ascontiguousarray(tone, dtype="<i2").tobytes(), "tone_waveform_hex.txt")
            print(f"[dry-run] generated waveform artifacts in {output_dir.resolve()}")
            return 0

        try:
            ctrl = RFSocController(
                args.ip,
                port=args.port,
                timeout_s=args.timeout,
                transport=args.transport,
                udp_interface=args.udp_interface,
                udp_source_ip=args.udp_source_ip,
            )
        except OSError as exc:
            raise SystemExit(
                f"Unable to connect to RFSoC board at {args.ip}:{args.port}: {exc}. "
                "Use --dry-run for offline validation or set RFSOC_BOARD_IP/RFSOC_BOARD_PORT."
            ) from exc

        try:
            end_channel = 0 if (args.transport == "tcp" or args.wait_for_trigger) else 15

            # 每个使能通道：DELAY 0 + PLAY(tone_bytes, ddr_addr)
            cmds = []
            for ch in channels:
                if args.ddr_layout == DDR_LAYOUT_INTERLEAVED_512B:
                    addr = 0
                    play_flags = PLAY_FLAG_INTERLEAVED
                elif args.ddr_layout == DDR_LAYOUT_TILED:
                    addr = tiled_channel_base_addr(ch)
                    play_flags = PLAY_FLAG_TILED
                else:
                    addr = DDR_CH_ADDR[ch - 1]
                    play_flags = 0
                cmds.append([1, ch, 0, 0])
                cmds.append([2, ch, tone_bytes, addr, play_flags])
            cmds.append([3, end_channel, 0, 0])

            if args.ddr_layout == DDR_LAYOUT_INTERLEAVED_512B:
                channel_waves = {ch: tone for ch in channels}
                dump = "interleaved_waveform_hex.txt"
                if args.transport == "tcp":
                    ctrl.upload_waveform_interleaved(channel_waves, ddr_addr=DDR_BASE, dump_path=dump)
                else:
                    ctrl.upload_waveform_udp_interleaved(channel_waves, base_addr=DDR_BASE, dump_path=dump)
            else:
                for ch in channels:
                    addr = tiled_channel_base_addr(ch) if args.ddr_layout == DDR_LAYOUT_TILED else DDR_CH_ADDR[ch - 1]
                    dump = f"ch{ch}_waveform_hex.txt"
                    if args.transport == "tcp":
                        ctrl.upload_waveform(tone, ddr_addr=addr, dump_path=dump)
                    elif args.ddr_layout == DDR_LAYOUT_TILED:
                        ctrl.upload_waveform_udp_tiled(tone, channel=ch, base_addr=DDR_BASE, dump_path=dump)
                    else:
                        ctrl.upload_waveform_udp(tone, ddr_addr=addr, dump_path=dump)

            if args.transport != "tcp" and args.udp_write_settle_s > 0:
                print(f"[udp-upload] waiting {args.udp_write_settle_s:.3f}s for DDR write completion")
                time.sleep(args.udp_write_settle_s)

            ctrl.send_instructions(cmds)
            if args.transport == "tcp":
                ctrl.trigger()
            print("Done.")
            return 0
        finally:
            ctrl.close()
    finally:
        os.chdir(old_cwd)


if __name__ == "__main__":
    raise SystemExit(main())
