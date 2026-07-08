import argparse
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
#   256-bit RFDC AXIS 字。NCO 频率由固件启动默认值或 DDR mailbox 设置。
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
DDR_TILE_BYTES = FIXED_DATA_BYTES = 4096
DDR_TILE_CHANNELS = 8
DDR_SUPERBLOCK_BYTES = DDR_TILE_BYTES * DDR_TILE_CHANNELS
PLAY_FLAG_LOOP = 0x1
PLAY_FLAG_TILED = 0x2
PLAY_FLAG_INTERLEAVED = 0x4
DDR_INTERLEAVED_LANE_BYTES = 8
DDR_INTERLEAVED_BEAT_BYTES = DDR_INTERLEAVED_LANE_BYTES * DDR_TILE_CHANNELS
DDR_INTERLEAVED_CHANNELS = DDR_TILE_CHANNELS
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
DDR_CH1_ADDR = 0x0000000000000000
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
SO_BINDTODEVICE = 25
UDP_WAVE_DDR_MAGIC = 0x5741564544445230  # WAVEDDR0
UDP_TRIGGER_WORD = 0x3152454747495254  # ASCII "TRIGGER1" on the UDP byte stream
RFDC_CTRL_MAILBOX_OFFSET = 0x0FF00000
RFDC_CTRL_MAILBOX_MAGIC = 0x304F434E43444652  # ASCII "RFDCNCO0" little-endian
RFDC_CTRL_MAILBOX_HEADER_BYTES = 32
RFDC_CTRL_MAILBOX_ENTRY_BYTES = 16
RFDC_CTRL_MAILBOX_CHANNELS = 8
RFDC_CTRL_MAILBOX_BYTES = RFDC_CTRL_MAILBOX_HEADER_BYTES + RFDC_CTRL_MAILBOX_ENTRY_BYTES * RFDC_CTRL_MAILBOX_CHANNELS
RFDC_CTRL_MAILBOX_FLAG_APPLY_IMMEDIATE = 0x1


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


def decode_udp_waveform_packet(packet: bytes) -> tuple[int, int, bytes]:
    """Decode one board-facing UDP DDR write packet for tests/ILA correlation."""
    if len(packet) != 48:
        raise ValueError(f"UDP DDR write packet must be 48 bytes, got {len(packet)}")
    magic, ddr_addr, word0, word1, word2, word3 = struct.unpack("<QQQQQQ", packet)
    if magic != UDP_WAVE_DDR_MAGIC:
        raise ValueError(f"bad UDP DDR magic 0x{magic:016X}")
    require_beat_aligned(ddr_addr, "ddr_addr")
    return magic, ddr_addr, struct.pack("<QQQQ", word0, word1, word2, word3)


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
            f"[udp-rfdc-mailbox] offset=0x{RFDC_CTRL_MAILBOX_OFFSET:08X}, "
            f"seq={int(seq) & 0xFFFFFFFF}, apply_mask=0x{int(apply_mask) & 0xFF:02X}, packets={packet_count}"
        )
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
