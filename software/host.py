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
#   每个 DAC tile 采样率 Fs = 6.0 GSPS，8 倍内插，
#   PL/AXIS 织物时钟 = Fs / interp / 8 = 93.75 MHz。
#   每个 256-bit tile 字 = 该 tile 两个物理 DAC（slice0 + slice2）
#   的复数样本；DDR 侧仍按 128-bit beat 组织，gearbox 把
#   相邻两 beat 合成一个 256-bit 字（beat0->slice0, beat1->slice2）。
#   NCO 频率由固件在启动时设置（默认 -1.5 GHz，Zone2 -> 4.5 GHz RF）。
DAC_TILE_FS = 6.0e9
DAC_INTERP = 8
DAC_FABRIC_HZ = DAC_TILE_FS / DAC_INTERP / 8  # 93.75 MHz
NCO_FREQ_GHZ = 4.5  # 仅作记录，实际由固件配置

# 单频 CW 的复基带置于 DC：I/Q 两路均为常数。
# 用「整片常数填充」的方式生成 DDR 数据，对 I/Q lane 的具体
# 排布（交织 or 分块）完全不敏感——无论哪种排布，常数填充都
# 等价于一个 DC 复基带矢量，经 NCO 上变频后在每个 DAC 上输出
# 唯一一根 NCO 频率的单频波，确保准确无误。
TONE_AMP = 0.5  # 每路 lane 占满量程的比例（C = round(amp*32767)）
TONE_BYTES_DEFAULT = 256 * 1024  # 每通道 DDR 缓冲字节数（32B 对齐）

DDR_BASE = 0x0000000000000000
DDR_CH_STRIDE = 0x0000000000200000  # 每通道间隔 2 MiB，避免缓冲重叠
DDR_CH_ADDR = [DDR_BASE + i * DDR_CH_STRIDE for i in range(4)]

# 兼容旧 GUI/工具子系统的共享常量与别名。
DDR_CH1_ADDR = DDR_CH_ADDR[0]
DDR_CH2_ADDR = DDR_CH_ADDR[1]
DDR_CH3_ADDR = DDR_CH_ADDR[2]
DDR_CH4_ADDR = DDR_CH_ADDR[3]
DDR_X_ADDR = DDR_CH1_ADDR
DDR_Y_ADDR = DDR_CH2_ADDR
# DAC tile 采样率与织物时钟（供 GUI 时间轴/速率换算使用）。
DAC_XY_FS = DAC_TILE_FS                  # 6.0 GS/s
DAC_AXIS_HZ = DAC_FABRIC_HZ              # 93.75 MHz
# 单帧固定字节数 / 样本数：一个 256-bit DAC 字 = 32B = 16 个 int16 lane。
FIXED_DATA_BYTES = 4096
NUM_SAMPLES = FIXED_DATA_BYTES // 2

DEFAULT_BOARD_IP = os.environ.get("RFSOC_BOARD_IP", "192.168.1.128")
DEFAULT_BOARD_PORT = int(os.environ.get("RFSOC_BOARD_PORT", "1234"))
DEFAULT_UDP_WRITE_SETTLE_S = float(os.environ.get("RFSOC_UDP_WRITE_SETTLE_S", "0.25"))
DEFAULT_UDP_INTERFACE = os.environ.get("RFSOC_UDP_INTERFACE", "")
DEFAULT_UDP_SOURCE_IP = os.environ.get("RFSOC_UDP_SOURCE_IP", "")
SO_BINDTODEVICE = 25
UDP_WAVE_DDR_MAGIC = 0x5741564544445230  # WAVEDDR0


def _normalize_waveform_int16(data_int16: np.ndarray, sample_count: int = NUM_SAMPLES) -> np.ndarray:
    """把 int16 波形裁剪/补零到 sample_count 个样本（供 GUI/工具子系统使用）。"""
    if data_int16.dtype != np.int16:
        data_int16 = data_int16.astype(np.int16)
    if len(data_int16) >= sample_count:
        return data_int16[:sample_count]
    pad = np.zeros(sample_count - len(data_int16), dtype=np.int16)
    return np.concatenate([data_int16, pad])


def iter_udp_waveform_packets(wave_bytes: bytes, ddr_addr: int):
    """把任意长度的波形字节流切成 16B 一组，封装成 UDP DDR 写包。

    每包：[magic(u64), ddr_addr(u64), low(u64), high(u64)] 小端。
    长度补齐到 16B。"""
    if len(wave_bytes) % 16 != 0:
        wave_bytes += b"\x00" * (16 - (len(wave_bytes) % 16))

    base_addr = int(ddr_addr) & 0xFFFFFFFFFFFFFFFF
    for offset in range(0, len(wave_bytes), 16):
        low, high = struct.unpack("<QQ", wave_bytes[offset:offset + 16])
        yield struct.pack("<QQQQ", UDP_WAVE_DDR_MAGIC, base_addr + offset, low, high)


# ============================================================
# 2. 波形生成（DC 复基带，单频 CW）
# ============================================================
def build_dc_iq_tone(n_bytes: int, amp: float = TONE_AMP) -> np.ndarray:
    """生成一段「常数填充」的 IQ DDR 缓冲。

    n_bytes 必须为 32 的倍数（一个 256-bit DAC 字 = 32B）。
    返回 int16 数组（小端写入 DDR），每个 lane 都是同一常数 C。
    经 NCO 上变频后等价于 DC 复基带 -> 单一 NCO 频率的 CW。"""
    if n_bytes % 32 != 0:
        n_bytes += 32 - (n_bytes % 32)
    c = int(round(float(amp) * 32767))
    c = max(-32768, min(32767, c))
    n_samples = n_bytes // 2
    return np.full(n_samples, c, dtype=np.int16)


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

    def send_instructions(self, cmd_list):
        """type=1：每条 16B：w0/w1/w2/w3"""
        bin_cmds = b""
        for cmd in cmd_list:
            # cmd=[op,ch,len_or_delay,addr] or [op,ch,len_or_delay,addr,flags]
            flags = int(cmd[4]) if len(cmd) > 4 else 0
            word0 = (int(cmd[1]) << 4) | (int(cmd[0]) & 0xF) | ((flags & 0x1) << 8)
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
        """type=2：GPIO 触发"""
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
    parser.add_argument("--channels", default="1,2,3,4",
                        help="Comma-separated executor channels to play (1..4 -> DAC tiles 0..3)")
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
    return parser.parse_args()


def main():
    args = parse_args()
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    channels = sorted({int(c) for c in args.channels.split(",") if c.strip()})
    for ch in channels:
        if ch < 1 or ch > 4:
            raise SystemExit(f"channel {ch} out of range (1..4)")

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
                cmds.append([1, ch, 0, 0])
                cmds.append([2, ch, tone_bytes, DDR_CH_ADDR[ch - 1]])
            cmds.append([3, end_channel, 0, 0])

            for ch in channels:
                addr = DDR_CH_ADDR[ch - 1]
                dump = f"ch{ch}_waveform_hex.txt"
                if args.transport == "tcp":
                    ctrl.upload_waveform(tone, ddr_addr=addr, dump_path=dump)
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
