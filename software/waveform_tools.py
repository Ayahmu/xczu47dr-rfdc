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


DEFAULT_CHANNEL_ADDRS = {
    1: host.DDR_CH1_ADDR,
    2: host.DDR_CH2_ADDR,
    3: host.DDR_CH3_ADDR,
    4: host.DDR_CH4_ADDR,
    5: host.DDR_CH5_ADDR,
    6: host.DDR_CH6_ADDR,
    7: host.DDR_CH7_ADDR,
    8: host.DDR_CH8_ADDR,
}

DEFAULT_DAC_PORTS = {
    1: "s00_axis",
    2: "s02_axis",
    3: "s10_axis",
    4: "s12_axis",
    5: "s20_axis",
    6: "s22_axis",
    7: "s30_axis",
    8: "s32_axis",
}

DEFAULT_DAC_OUTPUTS = {
    1: ("vout00",),
    2: ("vout02",),
    3: ("vout10",),
    4: ("vout12",),
    5: ("vout20",),
    6: ("vout22",),
    7: ("vout30",),
    8: ("vout32",),
}


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
    delay_s: float = 0.0,
    sample_count: int = host.NUM_SAMPLES,
) -> np.ndarray:
    n = np.arange(sample_count, dtype=np.float64)
    t = n / float(sample_rate_hz)
    sigma = float(duration_s) / 6.0
    center = float(duration_s) / 2.0
    env = np.exp(-0.5 * ((t - center) / sigma) ** 2)
    signal = env * np.cos((2.0 * np.pi * float(freq_hz) * t) + float(phase_rad))
    return np.round(np.clip(signal * float(amplitude), -32767.0, 32767.0)).astype(np.int16)


def pack_iq_tile_buffer(i_wave: np.ndarray, q_wave: np.ndarray, sample_count: int = host.NUM_SAMPLES) -> np.ndarray:
    if sample_count % host.INT16_PER_DACWORD != 0:
        raise ValueError("sample_count must be a whole number of 256-bit DAC words")
    complex_samples = int(sample_count) // 2
    i_samples = host._normalize_waveform_int16(i_wave, sample_count=complex_samples)
    q_samples = host._normalize_waveform_int16(q_wave, sample_count=complex_samples)
    packed = np.zeros(sample_count, dtype=np.int16)
    packed[0::2] = i_samples
    packed[1::2] = q_samples
    return packed


def make_iq_sine_tile_waveform(
    freq_hz: float,
    phase_rad: float,
    amplitude: int,
    sample_rate_hz: float,
    sample_count: int = host.NUM_SAMPLES,
) -> np.ndarray:
    complex_sample_count = int(sample_count) // 2
    n = np.arange(complex_sample_count, dtype=np.float64)
    angle = (2.0 * np.pi * float(freq_hz) * n / float(sample_rate_hz)) + float(phase_rad)
    i_wave = np.cos(angle) * float(amplitude)
    q_wave = np.sin(angle) * float(amplitude)
    return pack_iq_tile_buffer(
        np.round(np.clip(i_wave, -32767.0, 32767.0)).astype(np.int16),
        np.round(np.clip(q_wave, -32767.0, 32767.0)).astype(np.int16),
        sample_count=sample_count,
    )


def _pypulse_iq_burst(
    freq_hz: float,
    phase_rad: float,
    amplitude: int,
    sample_rate_hz: float,
    duration_s: float,
    sample_count: int,
) -> tuple[np.ndarray, np.ndarray]:
    n = np.arange(sample_count, dtype=np.float64)
    t = n / float(sample_rate_hz)
    sigma = float(duration_s) / 6.0
    center = float(duration_s) / 2.0
    env = np.exp(-0.5 * ((t - center) / sigma) ** 2)
    angle = (2.0 * np.pi * float(freq_hz) * t) + float(phase_rad)
    i_wave = env * np.cos(angle) * float(amplitude)
    q_wave = env * np.sin(angle) * float(amplitude)
    return (
        np.round(np.clip(i_wave, -32767.0, 32767.0)).astype(np.int16),
        np.round(np.clip(q_wave, -32767.0, 32767.0)).astype(np.int16),
    )


def _pypulse_z_envelope(amplitude: int, sample_rate_hz: float, duration_s: float, sample_count: int) -> np.ndarray:
    n = np.arange(sample_count, dtype=np.float64)
    t = n / float(sample_rate_hz)
    sigma = float(duration_s) / 6.0
    center = float(duration_s) / 2.0
    env = np.exp(-0.5 * ((t - center) / sigma) ** 2)
    return np.round(np.clip(env * float(amplitude), -32767.0, 32767.0)).astype(np.int16)


def make_pypulse_tile_waveform(
    waveform: str,
    freq_hz: float,
    phase_rad: float,
    amplitude: int,
    sample_rate_hz: float,
    duration_s: float,
    sample_count: int = host.NUM_SAMPLES,
) -> tuple[np.ndarray, dict[str, str]]:
    waveform_key = waveform.lower()
    complex_sample_count = sample_count // 2
    if waveform_key == "xy":
        i_wave, q_wave = _pypulse_iq_burst(freq_hz, phase_rad, amplitude, sample_rate_hz, duration_s, complex_sample_count)
        return pack_iq_tile_buffer(i_wave, q_wave, sample_count=sample_count), {"waveform": "xy", "i_signal": "xy_i", "q_signal": "xy_q"}
    if waveform_key == "readout":
        i_wave, q_wave = _pypulse_iq_burst(freq_hz, phase_rad, amplitude, sample_rate_hz, duration_s, complex_sample_count)
        return pack_iq_tile_buffer(i_wave, q_wave, sample_count=sample_count), {"waveform": "readout", "i_signal": "readout_i", "q_signal": "readout_q"}
    if waveform_key == "z":
        i_wave = _pypulse_z_envelope(amplitude, sample_rate_hz, duration_s, complex_sample_count)
        q_wave = np.zeros(complex_sample_count, dtype=np.int16)
        return pack_iq_tile_buffer(i_wave, q_wave, sample_count=sample_count), {"waveform": "z", "i_signal": "z_i", "q_signal": "zero_q"}
    raise ValueError("pypulse waveform must be one of: xy, z, readout")


def make_pypulse_waveform_bundle(
    sample_rate_hz: float,
    loop: bool,
    amplitude: int = 24000,
    duration_s: float = 120e-9,
    xy_freq_hz: float = 80e6,
    z_freq_hz: float = 0.0,
    readout_freq_hz: float = 120e6,
    phase_rad: float = 0.0,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray, dict[str, Any]]:
    ch1, ch1_meta = make_pypulse_tile_waveform("xy", xy_freq_hz, phase_rad, amplitude, sample_rate_hz, duration_s)
    ch2, ch2_meta = make_pypulse_tile_waveform("z", z_freq_hz, 0.0, amplitude, sample_rate_hz, duration_s)
    ch3, ch3_meta = make_pypulse_tile_waveform("readout", readout_freq_hz, phase_rad, amplitude, sample_rate_hz, duration_s)
    ch4, ch4_meta = make_pypulse_tile_waveform("readout", readout_freq_hz, phase_rad + np.pi / 2.0, amplitude, sample_rate_hz, duration_s)
    ch5, ch5_meta = make_pypulse_tile_waveform("xy", xy_freq_hz, phase_rad, amplitude, sample_rate_hz, duration_s)
    ch6, ch6_meta = make_pypulse_tile_waveform("z", z_freq_hz, 0.0, amplitude, sample_rate_hz, duration_s)
    ch7, ch7_meta = make_pypulse_tile_waveform("readout", readout_freq_hz, phase_rad, amplitude, sample_rate_hz, duration_s)
    ch8, ch8_meta = make_pypulse_tile_waveform("readout", readout_freq_hz, phase_rad + np.pi / 2.0, amplitude, sample_rate_hz, duration_s)
    metadata = build_metadata(
        mode="pypulse",
        sample_rate_hz=sample_rate_hz,
        encoding="signed-iq-interleaved",
        loop=loop,
        amplitude=amplitude,
        duration_s=duration_s,
        xy_freq_hz=xy_freq_hz,
        z_freq_hz=z_freq_hz,
        readout_freq_hz=readout_freq_hz,
        ch1_pypulse_waveform=ch1_meta["waveform"],
        ch1_i_signal=ch1_meta["i_signal"],
        ch1_q_signal=ch1_meta["q_signal"],
        ch2_pypulse_waveform=ch2_meta["waveform"],
        ch2_i_signal=ch2_meta["i_signal"],
        ch2_q_signal=ch2_meta["q_signal"],
        ch3_pypulse_waveform=ch3_meta["waveform"],
        ch3_i_signal=ch3_meta["i_signal"],
        ch3_q_signal=ch3_meta["q_signal"],
        ch4_pypulse_waveform=ch4_meta["waveform"],
        ch4_i_signal=ch4_meta["i_signal"],
        ch4_q_signal=ch4_meta["q_signal"],
        ch5_pypulse_waveform=ch5_meta["waveform"],
        ch5_i_signal=ch5_meta["i_signal"],
        ch5_q_signal=ch5_meta["q_signal"],
        ch6_pypulse_waveform=ch6_meta["waveform"],
        ch6_i_signal=ch6_meta["i_signal"],
        ch6_q_signal=ch6_meta["q_signal"],
        ch7_pypulse_waveform=ch7_meta["waveform"],
        ch7_i_signal=ch7_meta["i_signal"],
        ch7_q_signal=ch7_meta["q_signal"],
        ch8_pypulse_waveform=ch8_meta["waveform"],
        ch8_i_signal=ch8_meta["i_signal"],
        ch8_q_signal=ch8_meta["q_signal"],
    )
    return ch1, ch2, ch3, ch4, ch5, ch6, ch7, ch8, metadata


def make_incrementing_pattern(sample_count: int = host.NUM_SAMPLES, start: int = 0) -> np.ndarray:
    values = (np.arange(sample_count, dtype=np.int32) + int(start)) & 0xFFFF
    return values.astype(np.uint16).view(np.int16)


def _first_four_u64(samples: np.ndarray) -> tuple[int, int, int, int]:
    normalized = host._normalize_waveform_int16(samples, sample_count=16)
    wave_bytes = normalized.astype("<i2").tobytes()
    return struct.unpack("<QQQQ", wave_bytes[:32])


def expected_axi_wdata_hex(samples: np.ndarray) -> str:
    word0, word1, word2, word3 = _first_four_u64(samples)
    return f"0x{word3:016x}{word2:016x}{word1:016x}{word0:016x}"


def lane_bytes_hex(samples: np.ndarray) -> str:
    normalized = host._normalize_waveform_int16(samples, sample_count=16)
    return normalized.astype("<i2").tobytes()[:32].hex(" ")


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


def delay_seconds_to_axis_cycles(
    delay_s: float,
    sample_rate_hz: float = host.DAC_XY_FS,
    samples_per_axis_cycle: int = host.RFDC_INTERPOLATION * 8,
) -> int:
    axis_hz = float(sample_rate_hz) / int(samples_per_axis_cycle)
    return max(0, int(round(float(delay_s) * axis_hz)))


def delay_ns_to_axis_cycles(delay_ns: float, axis_freq_hz: float = host.DAC_AXIS_HZ) -> int:
    return max(0, int(round(float(delay_ns) * float(axis_freq_hz) / 1e9)))


def delay_seconds_to_axis_cycles_by_freq(delay_s: float, axis_freq_hz: float = host.DAC_AXIS_HZ) -> int:
    return delay_ns_to_axis_cycles(float(delay_s) * 1e9, axis_freq_hz)


def build_play_commands(
    loop: bool,
    auto_start: bool,
    x_addr: int = host.DDR_X_ADDR,
    y_addr: int = host.DDR_Y_ADDR,
    length_bytes: int = host.FIXED_DATA_BYTES,
    channel_addrs: dict[int, int] | None = None,
    channel_delays: dict[int, int] | None = None,
) -> list[list[int]]:
    end_channel = 15 if auto_start else 0
    loop_flag = 1 if loop else 0
    addrs = dict(DEFAULT_CHANNEL_ADDRS if channel_addrs is None else channel_addrs)
    delays = {} if channel_delays is None else {int(channel): int(delay) for channel, delay in channel_delays.items()}
    addrs[1] = int(x_addr)
    addrs[2] = int(y_addr)
    commands: list[list[int]] = []
    for channel in sorted(addrs):
        commands.append([1, int(channel), max(0, delays.get(int(channel), 0)), 0])
        commands.append([2, int(channel), int(length_bytes), int(addrs[channel])])
    commands.append([3, end_channel, 0, 0, loop_flag])
    return commands


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
    for channel, ddr_addr in DEFAULT_CHANNEL_ADDRS.items():
        metadata[f"ch{channel}_ddr_offset"] = f"0x{ddr_addr:016X}"
        metadata[f"ch{channel}_dac_port"] = DEFAULT_DAC_PORTS[channel]
        metadata[f"ch{channel}_dac_outputs"] = list(DEFAULT_DAC_OUTPUTS[channel])
    if x_freq_hz is not None:
        metadata["x_freq_hz"] = float(x_freq_hz)
        metadata["x_cycles_in_record"] = float(x_freq_hz) * record_duration_s
    if y_freq_hz is not None:
        metadata["y_freq_hz"] = float(y_freq_hz)
        metadata["y_cycles_in_record"] = float(y_freq_hz) * record_duration_s
    metadata.update(extra)
    return metadata


def _save_named_waveform(out_dir: Path, name: str, samples: np.ndarray) -> None:
    wave_bytes = waveform_bytes(samples)
    np.save(out_dir / f"{name}_waveform.npy", samples)
    (out_dir / f"{name}_waveform_int16_le.bin").write_bytes(wave_bytes)
    np.savetxt(out_dir / f"{name}_waveform.csv", samples, fmt="%d", delimiter=",")
    host.RFSocController._save_hex_text(wave_bytes, str(out_dir / f"{name}_waveform_hex.txt"))


def save_waveform_bundle(
    out_dir: Path,
    x: np.ndarray,
    y: np.ndarray,
    metadata: dict[str, Any],
    stem: str = "waveform",
    ch3: np.ndarray | None = None,
    ch4: np.ndarray | None = None,
    extra_channels: dict[int, np.ndarray] | None = None,
    channel_delays: dict[int, int] | None = None,
) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    _save_named_waveform(out_dir, "x", x)
    _save_named_waveform(out_dir, "y", y)
    _save_named_waveform(out_dir, "ch1", x)
    _save_named_waveform(out_dir, "ch2", y)
    if ch3 is not None:
        _save_named_waveform(out_dir, "ch3", ch3)
    if ch4 is not None:
        _save_named_waveform(out_dir, "ch4", ch4)
    if extra_channels is not None:
        for channel, samples in sorted(extra_channels.items()):
            _save_named_waveform(out_dir, f"ch{int(channel)}", samples)
    (out_dir / f"{stem}_metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")


def save_waveform_artifacts(
    out_dir: Path,
    x: np.ndarray,
    y: np.ndarray,
    metadata: dict[str, Any],
    prefix: str = "waveform",
    ch3: np.ndarray | None = None,
    ch4: np.ndarray | None = None,
) -> None:
    save_waveform_bundle(out_dir, x, y, metadata, stem=prefix, ch3=ch3, ch4=ch4)


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
    ch3: np.ndarray | None = None,
    ch4: np.ndarray | None = None,
    extra_channels: dict[int, np.ndarray] | None = None,
    channel_delays: dict[int, int] | None = None,
) -> None:
    ctrl = host.RFSocController(
        ip,
        port=port,
        transport="udp",
        udp_interface=udp_interface,
        udp_source_ip=udp_source_ip,
        timeout_s=timeout_s,
    )
    uploads: list[tuple[int, np.ndarray, int, str]] = [
        (1, x, host.DDR_CH1_ADDR, "ch1_upload_hex.txt"),
        (2, y, host.DDR_CH2_ADDR, "ch2_upload_hex.txt"),
    ]
    if ch3 is not None:
        uploads.append((3, ch3, host.DDR_CH3_ADDR, "ch3_upload_hex.txt"))
    if ch4 is not None:
        uploads.append((4, ch4, host.DDR_CH4_ADDR, "ch4_upload_hex.txt"))
    if extra_channels is not None:
        for channel, samples in sorted(extra_channels.items()):
            uploads.append((int(channel), samples, DEFAULT_CHANNEL_ADDRS[int(channel)], f"ch{int(channel)}_upload_hex.txt"))

    try:
        for _, samples, ddr_addr, filename in uploads:
            ctrl.upload_waveform_udp(samples, ddr_addr, str(output_dir / filename))
        if post_upload_sleep_s > 0:
            time.sleep(post_upload_sleep_s)
        channel_addrs = {channel: ddr_addr for channel, _, ddr_addr, _ in uploads}
        ctrl.send_instructions(build_play_commands(loop=loop, auto_start=auto_start, channel_addrs=channel_addrs, channel_delays=channel_delays))
    finally:
        ctrl.close()
