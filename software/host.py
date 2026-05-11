import socket
import struct
import numpy as np

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


# ============================================================
# 1. 硬件参数
# ============================================================
DAC_XY_FS = 4.608e9
FIXED_DATA_BYTES = 4096
NUM_SAMPLES = FIXED_DATA_BYTES // 2
DELAY = 1

DDR_BASE = 0x500000000
DDR_X_ADDR = DDR_BASE
DDR_Y_ADDR = DDR_BASE + 0x1000  # 4096 对齐


# ============================================================
# 2. 波形生成
# ============================================================
def time_to_samples(duration_s, fs):
    return int(np.round(duration_s * fs))

def gaussian_env(duration_s, fs, amp):
    length = time_to_samples(duration_s, fs)
    n = np.arange(length)
    sigma = length / 6
    env = amp * np.exp(-(n - length / 2) ** 2 / (2 * sigma ** 2))
    return env

def add_timing(signal, delay_s, fs):
    delay_samples = time_to_samples(delay_s, fs)
    out = np.zeros(NUM_SAMPLES, dtype=np.float32)
    end = min(delay_samples + len(signal), NUM_SAMPLES)
    out[delay_samples:end] = signal[:end - delay_samples]
    return out

def generate_rf_burst(freq, duration_s, delay_s, fs, interpolation, amp=0.8):
    env = gaussian_env(duration_s / interpolation, fs, amp)
    t_local = np.arange(len(env)) / fs
    rf = env * np.cos(2 * np.pi * freq * interpolation * t_local)
    return add_timing(rf, delay_s / interpolation, fs)

def quantize_to_int16_array(signal):
    signal = np.clip(signal, -1.0, 1.0)
    return np.round(signal * 32767).astype(np.int16)


# ============================================================
# 3. 发送控制
# ============================================================
class RFSocController:
    def __init__(self, ip, port=7, timeout_s=5.0):
        self.ip = ip
        self.port = port
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.settimeout(timeout_s)
        self.sock.connect((ip, port))

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass

    def _send_packet(self, p_type, data: bytes):
        """发送 [Type(u32), Len(u32), Data] 小端"""
        header = struct.pack("<II", p_type, len(data))
        self.sock.sendall(header + data)
        return self.sock.recv(1024)  # 等待 ACK

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
        """
        type=0 payload 格式：
          [uint64 ddr_addr (little endian)] + [wave bytes...]
        wave bytes 固定对齐到 4096B (2048 samples of int16)
        """
        if data_int16.dtype != np.int16:
            data_int16 = data_int16.astype(np.int16)

        if len(data_int16) >= NUM_SAMPLES:
            data_int16 = data_int16[:NUM_SAMPLES]
        else:
            pad = np.zeros(NUM_SAMPLES - len(data_int16), dtype=np.int16)
            data_int16 = np.concatenate([data_int16, pad])

        wave_bytes = data_int16.astype("<i2").tobytes()

        # dump 仅 dump 波形本体（不含 addr 头），更直观对比 DDR 内容
        self._save_hex_text(wave_bytes, dump_path, bytes_per_line=16, style=dump_style)
        print(f"[dump] {dump_path}  ({len(wave_bytes)} bytes)")

        payload = struct.pack("<Q", int(ddr_addr) & 0xFFFFFFFFFFFFFFFF) + wave_bytes
        print(f"[upload] addr=0x{ddr_addr:016X}, payload={len(payload)} bytes (8+{len(wave_bytes)})")

        return self._send_packet(0, payload)

    def send_instructions(self, cmd_list):
        """type=1：每条 16B：w0/w1/w2/w3"""
        bin_cmds = b""
        for cmd in cmd_list:
            # cmd=[op,ch,len_or_delay,addr]
            word0 = (cmd[1] << 4) | (cmd[0] & 0xF)
            word1 = int(cmd[2]) & 0xFFFFFFFF
            addr = int(cmd[3]) & 0xFFFFFFFFFFFFFFFF
            word2 = addr & 0xFFFFFFFF
            word3 = (addr >> 32) & 0xFFFFFFFF
            bin_cmds += struct.pack("<IIII", word0, word1, word2, word3)

        print(f"[instr] Sending {len(cmd_list)} instructions, {len(bin_cmds)} bytes")
        return self._send_packet(1, bin_cmds)

    def trigger(self):
        """type=2：GPIO 触发"""
        print("[trig] GO")
        return self._send_packet(2, b"GO")


# ============================================================
# 4. Plot 工具
# ============================================================
def plot_waveforms(qx: np.ndarray, qy: np.ndarray, n_preview: int = 400, title_prefix: str = ""):
    plt.figure(figsize=(12, 5))
    plt.plot(qx[:n_preview], label="X (CH1) int16")
    plt.plot(qx[:n_preview], label="X (CH2) int16")
    plt.title(f"{title_prefix}Waveform Preview (first {n_preview} samples)")
    plt.xlabel("Sample")
    plt.ylabel("Amplitude (int16)")
    plt.grid(True)
    plt.legend()
    plt.tight_layout()
    plt.savefig("wave_preview_firstN.png", dpi=150)
    plt.close()

    plt.figure(figsize=(12, 5))
    plt.plot(qx, label="X (CH1) int16")
    plt.plot(qx, label="X (CH2) int16")
    plt.title(f"{title_prefix}Waveform Full Length ({len(qx)} samples)")
    plt.xlabel("Sample")
    plt.ylabel("Amplitude (int16)")
    plt.grid(True)
    plt.legend()
    plt.tight_layout()
    plt.savefig("wave_preview_full.png", dpi=150)
    plt.close()

    print("[plot] saved: wave_preview_firstN.png, wave_preview_full.png")


# ============================================================
# 5. 主程序
# ============================================================
if __name__ == "__main__":
    Interpolation = 4
    RF_FREQ = 0.250e9

    x_wave = generate_rf_burst(
        freq=RF_FREQ, duration_s=100e-9, delay_s=0,
        fs=DAC_XY_FS, interpolation=Interpolation, amp=0.8
    )
    y_wave = generate_rf_burst(
        freq=RF_FREQ, duration_s=20e-9, delay_s=15e-9,
        fs=DAC_XY_FS, interpolation=Interpolation, amp=0.8
    )

    qx = quantize_to_int16_array(x_wave)
    qy = quantize_to_int16_array(y_wave)

    # 对齐长度（2048 samples）
    qx = (np.concatenate([qx, np.zeros(NUM_SAMPLES - len(qx), dtype=np.int16)])
          if len(qx) < NUM_SAMPLES else qx[:NUM_SAMPLES])
    qy = (np.concatenate([qy, np.zeros(NUM_SAMPLES - len(qy), dtype=np.int16)])
          if len(qy) < NUM_SAMPLES else qy[:NUM_SAMPLES])

    plot_waveforms(qx, qy, n_preview=400, title_prefix="Before Send: ")

    ctrl = RFSocController("10.87.5.241", port=7)

    # 关键：上传时带 DDR 目标地址
    ctrl.upload_waveform(qx, ddr_addr=DDR_X_ADDR, dump_path="x_waveform_hex.txt")
    ctrl.upload_waveform(qy, ddr_addr=DDR_Y_ADDR, dump_path="y_waveform_hex.txt")

    cmds = [
        [1, 1, 0, 0],                           # ch1 idle delay=0
        [2, 1, FIXED_DATA_BYTES, DDR_X_ADDR],   # ch1 play
        [1, 2, 0, 0],                          # ch2 idle delay=0
        [2, 2, FIXED_DATA_BYTES, DDR_X_ADDR],   # ch2 play
        [3, 0, 0, 0]                            # END
    ]

    ctrl.send_instructions(cmds)
    ctrl.trigger()
    print("Done.")
    ctrl.close()