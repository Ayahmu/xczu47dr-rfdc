#!/usr/bin/env python3
"""Shared waveform generation and RFSoC playback helpers."""

from __future__ import annotations

import json
import struct
import time
from pathlib import Path
from typing import Any

import numpy as np

import host


def waveform_bytes(wave: np.ndarray) -> bytes:
    return wave.astype("<i2").tobytes()


def make_sine(
    freq_hz: float,
    phase_rad: float,
    amplitude: int,
    sample_rate_hz: float,
    sample_count: int = host.NUM_SAMPLES,
    encoding: str = "signed",
) -> np.ndarray:
    n = np.arange(sample_count, dtype=np.float64)
    wave = float(amplitude) * np.sin((2.0 * np.pi * float(freq_hz) * n / float(sample_rate_hz)) + float(phase_rad))
    if encoding == "signed":
        return np.round(np.clip(wave, -32767, 32767)).astype(np.int16)
    if encoding == "offset-binary":
        raw_u16 = np.round(np.clip(32768.0 + wave, 0.0, 65535.0)).astype(np.uint16)
        return raw_u16.view(np.int16)
    raise ValueError(f"Unsupported encoding: {encoding}")


def make_gaussian_burst(
    freq_hz: float,
    phase_rad: float,
    amplitude: int,
    sample_rate_hz: float,
    duration_s: float,
    delay_s: float,
    sample_count: int = host.NUM_SAMPLES,
) -> np.ndarray:
    n = np.arange(sample_count, dtype=np.float64)
    t = n / float(sample_rate_hz)
    sigma = float(duration_s) / 6.0
    center = float(delay_s) + (float(duration_s) / 2.0)
    env = np.exp(-0.5 * ((t - center) / sigma) ** 2)
    signal = env * np.cos((2.0 * np.pi * float(freq_hz) * (t - float(delay_s))) + float(phase_rad))
    return np.round(np.clip(signal * float(amplitude), -32767.0, 32767.0)).astype(np.int16)


def make_incrementing_pattern(sample_count: int = host.NUM_SAMPLES, start: int = 0) -> np.ndarray:
    values = (np.arange(sample_count, dtype=np.int32) + int(start)) & 0xFFFF
    return values.astype(np.uint16).view(np.int16)


def _first_two_u64(samples: np.ndarray) -> tuple[int, int]:
    normalized = host._normalize_waveform_int16(samples, sample_count=8)
    wave_bytes = normalized.astype("<i2").tobytes()
    return struct.unpack("<QQ", wave_bytes[:16])


def expected_axi_wdata_hex(samples: np.ndarray) -> str:
    low, high = _first_two_u64(samples)
    return f"0x{high:016x}{low:016x}"


def lane_bytes_hex(samples: np.ndarray) -> str:
    normalized = host._normalize_waveform_int16(samples, sample_count=8)
    return normalized.astype("<i2").tobytes()[:16].hex(" ")


def play_instruction_words(channel: int, length_bytes: int, ddr_addr: int) -> tuple[int, int]:
    word0 = (int(channel) << 4) | 0x2
    payload = struct.pack(
        "<IIII",
        word0,
        int(length_bytes) & 0xFFFFFFFF,
        int(ddr_addr) & 0xFFFFFFFF,
        (int(ddr_addr) >> 32) & 0xFFFFFFFF,
    )
    return struct.unpack("<QQ", payload)


def rtl_instruction_tdata_hex(words: tuple[int, int]) -> str:
    first, second = words
    return f"0x{second:016x}{first:016x}"


def build_play_commands(
    loop: bool,
    auto_start: bool,
    x_addr: int = host.DDR_X_ADDR,
    y_addr: int = host.DDR_Y_ADDR,
    length_bytes: int = host.FIXED_DATA_BYTES,
) -> list[list[int]]:
    end_channel = 15 if auto_start else 0
    loop_flag = 1 if loop else 0
    return [
        [1, 1, 0, 0],
        [2, 1, int(length_bytes), int(x_addr)],
        [1, 2, 0, 0],
        [2, 2, int(length_bytes), int(y_addr)],
        [3, end_channel, 0, 0, loop_flag],
    ]


def build_metadata(
    mode: str,
    sample_rate_hz: float,
    encoding: str,
    loop: bool,
    x_freq_hz: float | None = None,
    y_freq_hz: float | None = None,
    **extra: Any,
) -> dict[str, Any]:
    record_duration_s = host.NUM_SAMPLES / float(sample_rate_hz)
    metadata: dict[str, Any] = {
        "mode": mode,
        "sample_format": "16-bit little-endian raw DAC codes",
        "encoding": encoding,
        "sample_rate_hz": float(sample_rate_hz),
        "record_duration_s": record_duration_s,
        "samples_per_channel": int(host.NUM_SAMPLES),
        "bytes_per_channel": int(host.FIXED_DATA_BYTES),
        "x_ddr_offset": f"0x{host.DDR_X_ADDR:016X}",
        "y_ddr_offset": f"0x{host.DDR_Y_ADDR:016X}",
        "loop": bool(loop),
    }
    if x_freq_hz is not None:
        metadata["x_freq_hz"] = float(x_freq_hz)
        metadata["x_cycles_in_record"] = float(x_freq_hz) * record_duration_s
    if y_freq_hz is not None:
        metadata["y_freq_hz"] = float(y_freq_hz)
        metadata["y_cycles_in_record"] = float(y_freq_hz) * record_duration_s
    metadata.update(extra)
    return metadata


def save_waveform_bundle(out_dir: Path, x: np.ndarray, y: np.ndarray, metadata: dict[str, Any], stem: str = "waveform") -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    x_bytes = waveform_bytes(x)
    y_bytes = waveform_bytes(y)

    np.save(out_dir / "x_waveform.npy", x)
    np.save(out_dir / "y_waveform.npy", y)
    (out_dir / "x_waveform_int16_le.bin").write_bytes(x_bytes)
    (out_dir / "y_waveform_int16_le.bin").write_bytes(y_bytes)
    np.savetxt(out_dir / "x_waveform.csv", x, fmt="%d", delimiter=",")
    np.savetxt(out_dir / "y_waveform.csv", y, fmt="%d", delimiter=",")
    host.RFSocController._save_hex_text(x_bytes, str(out_dir / "x_waveform_hex.txt"))
    host.RFSocController._save_hex_text(y_bytes, str(out_dir / "y_waveform_hex.txt"))
    (out_dir / f"{stem}_metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")


def save_waveform_artifacts(out_dir: Path, x: np.ndarray, y: np.ndarray, metadata: dict[str, Any], prefix: str = "waveform") -> None:
    save_waveform_bundle(out_dir, x, y, metadata, stem=prefix)


def upload_and_play(
    x: np.ndarray,
    y: np.ndarray,
    ip: str,
    port: int,
    udp_interface: str,
    udp_source_ip: str,
    timeout_s: float,
    post_upload_sleep_s: float,
    output_dir: Path,
    loop: bool,
    auto_start: bool = True,
) -> None:
    ctrl = host.RFSocController(
        ip,
        port=port,
        transport="udp",
        udp_interface=udp_interface,
        udp_source_ip=udp_source_ip,
        timeout_s=timeout_s,
    )
    try:
        ctrl.upload_waveform_udp(x, host.DDR_X_ADDR, str(output_dir / "x_upload_hex.txt"))
        ctrl.upload_waveform_udp(y, host.DDR_Y_ADDR, str(output_dir / "y_upload_hex.txt"))
        if post_upload_sleep_s > 0:
            time.sleep(post_upload_sleep_s)
        ctrl.send_instructions(build_play_commands(loop=loop, auto_start=auto_start))
    finally:
        ctrl.close()
