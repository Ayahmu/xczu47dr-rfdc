#!/usr/bin/env python3
"""Shared waveform generation and RFSoC playback helpers."""

from __future__ import annotations

import json
import struct
import time
from pathlib import Path
from typing import Any, Literal

import numpy as np

import host
from dr47.waveforms import (
    iq_duration_to_interleaved_sample_count as _driver_iq_duration_to_sample_count,
    make_iq_gaussian_sine_interleaved as _driver_make_iq_gaussian_sine,
    make_iq_sine_interleaved as _driver_make_iq_sine,
)


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

DEFAULT_INTERLEAVED_CHANNEL_ADDRS = {
    channel: host.interleaved_channel_lane_addr(channel)
    for channel in range(1, 9)
}

DEFAULT_TILED_CHANNEL_ADDRS = {
    channel: host.tiled_channel_base_addr(channel)
    for channel in range(1, 9)
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


def iq_duration_to_sample_count(duration_s: float, sample_rate_hz: float) -> int:
    """Return an int16 sample count for a finite I/Q record.

    `sample_rate_hz` is the complex I/Q sample rate. The returned raw int16
    count is rounded up to a whole 256-bit DAC word so UDP writes and DataMover
    BTT remain 32B aligned.
    """
    return _driver_iq_duration_to_sample_count(duration_s, sample_rate_hz)


def waveform_length_bytes(samples: np.ndarray) -> int:
    length_bytes = int(np.asarray(samples).size) * 2
    if length_bytes % host.BEAT_BYTES != 0:
        length_bytes += host.BEAT_BYTES - (length_bytes % host.BEAT_BYTES)
    return length_bytes


def append_iq_zero_tail(samples: np.ndarray, zero_tail_s: float, sample_rate_hz: float) -> np.ndarray:
    """Append aligned zero I/Q samples so finite records end at complex zero."""
    tail_s = float(zero_tail_s)
    if tail_s <= 0.0:
        return np.asarray(samples, dtype=np.int16)
    tail_samples = iq_duration_to_sample_count(tail_s, sample_rate_hz)
    return np.concatenate([
        np.asarray(samples, dtype=np.int16),
        np.zeros(tail_samples, dtype=np.int16),
    ])


def make_iq_sine_tile_waveform(
    freq_hz: float,
    phase_rad: float,
    amplitude: int,
    sample_rate_hz: float,
    sample_count: int = host.NUM_SAMPLES,
    q_sign: int = -1,
) -> np.ndarray:
    return _driver_make_iq_sine(
        freq_hz, phase_rad, amplitude, sample_rate_hz, sample_count=sample_count, q_sign=q_sign
    )


def make_iq_gaussian_sine_tile_waveform(
    freq_hz: float,
    phase_rad: float,
    amplitude: int,
    sample_rate_hz: float,
    duration_s: float,
    sample_count: int | None = None,
    fwhm_s: float | None = None,
    q_sign: int = -1,
    hls_xy_drag: bool = True,
    drag_alpha: float = 0.5,
    drag_delta_hz: float = -200e6,
) -> np.ndarray:
    """Generate a finite I/Q sine with a Gaussian envelope.

    The default FWHM follows the HLS XY pulse convention:
    piLen=60 ns and piFWHM=30 ns, i.e. FWHM = duration / 2.
    When ``hls_xy_drag`` is enabled, a DRAG-like quadrature derivative term is
    added to match the shape of the HLS ``rotPulseHD_xy`` generator.
    """
    return _driver_make_iq_gaussian_sine(
        freq_hz, phase_rad, amplitude, sample_rate_hz, duration_s, sample_count=sample_count,
        fwhm_s=fwhm_s, q_sign=q_sign, hls_xy_drag=hls_xy_drag,
        drag_alpha=drag_alpha, drag_delta_hz=drag_delta_hz,
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
    layout: str = host.DEFAULT_DDR_LAYOUT,
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
        layout=layout,
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


def play_instruction_words(channel: int, length_bytes: int, ddr_addr: int, flags: int = 0) -> tuple[int, int]:
    word0 = (int(channel) << 4) | 0x2 | ((int(flags) & 0x7) << 8)
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
    sample_rate_hz: float = host.DAC_IQ_SAMPLE_RATE_HZ,
    samples_per_axis_cycle: int = 8,
) -> int:
    axis_hz = float(sample_rate_hz) / int(samples_per_axis_cycle)
    return max(0, int(round(float(delay_s) * axis_hz)))


def delay_ns_to_axis_cycles(delay_ns: float, axis_freq_hz: float = host.DAC_FABRIC_HZ) -> int:
    return max(0, int(round(float(delay_ns) * float(axis_freq_hz) / 1e9)))


def delay_seconds_to_axis_cycles_by_freq(delay_s: float, axis_freq_hz: float = host.DAC_FABRIC_HZ) -> int:
    return delay_ns_to_axis_cycles(float(delay_s) * 1e9, axis_freq_hz)


def build_play_commands(
    loop: bool,
    auto_start: bool,
    x_addr: int = host.DDR_X_ADDR,
    y_addr: int = host.DDR_Y_ADDR,
    length_bytes: int = host.FIXED_DATA_BYTES,
    channel_addrs: dict[int, int] | None = None,
    channel_lengths: dict[int, int] | None = None,
    channel_delays: dict[int, int] | None = None,
    enabled_channels: set[int] | list[int] | tuple[int, ...] | None = None,
    layout: str = host.DEFAULT_DDR_LAYOUT,
) -> list[list[int]]:
    if layout not in {host.DDR_LAYOUT_CONTIGUOUS, host.DDR_LAYOUT_TILED, host.DDR_LAYOUT_INTERLEAVED_512B}:
        raise ValueError(f"unsupported DDR layout: {layout}")
    end_channel = 15 if auto_start else 0
    loop_flag = 1 if loop else 0
    if layout == host.DDR_LAYOUT_INTERLEAVED_512B:
        default_addrs = DEFAULT_INTERLEAVED_CHANNEL_ADDRS
        play_flag = host.PLAY_FLAG_INTERLEAVED
    elif layout == host.DDR_LAYOUT_TILED:
        default_addrs = DEFAULT_TILED_CHANNEL_ADDRS
        play_flag = host.PLAY_FLAG_TILED
    else:
        default_addrs = DEFAULT_CHANNEL_ADDRS
        play_flag = 0
    addrs = dict(default_addrs if channel_addrs is None else channel_addrs)
    if enabled_channels is not None:
        enabled = {int(channel) for channel in enabled_channels}
        if not enabled:
            raise ValueError("enabled_channels must not be empty")
        addrs = {channel: addr for channel, addr in addrs.items() if int(channel) in enabled}
        if not addrs:
            raise ValueError("enabled_channels did not match any channel addresses")
    lengths = {} if channel_lengths is None else {int(channel): int(length) for channel, length in channel_lengths.items()}
    delays = {} if channel_delays is None else {int(channel): int(delay) for channel, delay in channel_delays.items()}
    if layout == host.DDR_LAYOUT_INTERLEAVED_512B:
        for channel in list(addrs.keys()):
            addrs[channel] = 0
    elif layout == host.DDR_LAYOUT_CONTIGUOUS and channel_addrs is None:
        addrs[1] = int(x_addr)
        addrs[2] = int(y_addr)
    commands: list[list[int]] = []
    for channel in sorted(addrs):
        play_bytes = int(lengths.get(int(channel), length_bytes))
        if play_bytes % host.BEAT_BYTES != 0:
            play_bytes += host.BEAT_BYTES - (play_bytes % host.BEAT_BYTES)
        commands.append([1, int(channel), max(0, delays.get(int(channel), 0)), 0])
        commands.append([2, int(channel), play_bytes, int(addrs[channel]), play_flag])
    commands.append([3, end_channel, 0, 0, loop_flag])
    return commands


def ezq_wave_to_interleaved_int16(
    wave: np.ndarray | list,
    wave_format: Literal["iq_matrix", "packed_iq", "interleaved_iq"] = "packed_iq",
) -> np.ndarray:
    """Convert ez-Q style wave data into little-endian interleaved int16 lanes.

    Supported inputs:
    - ``iq_matrix``: 2-D ndarray/list, row 0 is I and row 1 is Q.
    - ``packed_iq``: 1-D packed ``int32`` IQ words (``Q<<16 | I``).
    - ``interleaved_iq``: 1-D interleaved ``int16`` lanes (I, Q, I, Q, ...).
    """
    arr = np.asarray(wave)
    if wave_format == "iq_matrix":
        if arr.ndim != 2:
            raise ValueError("iq_matrix wave must be 2-D with row 0=I and row 1=Q")
        if arr.shape[0] == 2:
            i_data, q_data = arr[0], arr[1]
        elif arr.shape[1] == 2:
            i_data, q_data = arr[:, 0], arr[:, 1]
        else:
            raise ValueError("iq_matrix wave must have exactly two I/Q axes")
        i_data = np.ascontiguousarray(i_data, dtype="<i2").reshape(-1)
        q_data = np.ascontiguousarray(q_data, dtype="<i2").reshape(-1)
        if i_data.shape != q_data.shape:
            raise ValueError("I and Q vectors must have the same length")
        out = np.empty(i_data.size * 2, dtype=np.int16)
        out[0::2] = i_data
        out[1::2] = q_data
        return out

    if wave_format == "packed_iq":
        packed = np.ascontiguousarray(arr, dtype="<i4").reshape(-1)
        return packed.view("<i2").copy()

    if wave_format == "interleaved_iq":
        interleaved = np.ascontiguousarray(arr, dtype="<i2").reshape(-1)
        if interleaved.size % 2 != 0:
            raise ValueError("interleaved_iq wave must contain an even number of int16 lanes")
        return interleaved.copy()

    raise ValueError(f"Unsupported ez-Q wave format: {wave_format}")


def ezq_wave_to_packed_int32(
    wave: np.ndarray | list,
    wave_format: Literal["iq_matrix", "packed_iq", "interleaved_iq"] = "packed_iq",
) -> np.ndarray:
    """Convert ez-Q style wave data into packed int32 IQ words."""
    if wave_format == "packed_iq":
        return np.ascontiguousarray(np.asarray(wave), dtype="<i4").reshape(-1)
    interleaved = ezq_wave_to_interleaved_int16(wave, wave_format=wave_format).astype("<i2", copy=False)
    if interleaved.size % 2 != 0:
        raise ValueError("IQ lane count must be even")
    i_data = interleaved[0::2].astype(np.int32)
    q_data = interleaved[1::2].astype(np.int32)
    return ((q_data & 0xFFFF) << 16) | (i_data & 0xFFFF)


def ezq_sequence_rows(sequence: np.ndarray | list) -> np.ndarray:
    """Normalize ez-Q control sequence rows to ``uint16`` with shape ``(n, 4)``."""
    rows = np.asarray(sequence, dtype="<u2")
    if rows.size == 0:
        return rows.reshape(0, 4)
    if rows.ndim == 1:
        if rows.size % 4 != 0:
            raise ValueError("flat ez-Q seq must contain a multiple of 4 words")
        return rows.reshape(-1, 4)
    if rows.ndim == 2 and rows.shape[1] == 4:
        return np.ascontiguousarray(rows, dtype="<u2")
    raise ValueError("ez-Q seq must be a flat 4-word list or an (n, 4) array")


def ezq_sequence_flags(sequence: np.ndarray | list) -> dict[str, bool]:
    rows = ezq_sequence_rows(sequence)
    funcs = ((rows[:, 3] >> 11) & 0xF).tolist() if rows.size else []
    return {
        "has_trigger": 8 in funcs,
        "has_loop_start": 1 in funcs,
        "has_loop_end": 2 in funcs,
        "has_delay": 4 in funcs,
        "has_stop": any(((rows[:, 3] >> 15) & 0x1).tolist()) if rows.size else False,
    }


def _ezq_sequence_delay_cycles(sequence: np.ndarray | list, default: int = 0) -> int:
    rows = ezq_sequence_rows(sequence)
    if rows.size == 0:
        return int(default)
    funcs = (rows[:, 3] >> 11) & 0xF
    delay_rows = rows[funcs == 4]
    if delay_rows.size == 0:
        return int(default)
    return int(delay_rows[0, 2])


def save_ezq_wave_bundle(
    out_dir: Path,
    channel_waves: dict[int, np.ndarray | list],
    metadata: dict[str, Any],
    channel_sequences: dict[int, np.ndarray | list] | None = None,
    channel_format: Literal["iq_matrix", "packed_iq", "interleaved_iq"] = "interleaved_iq",
    stem: str = "ezq",
) -> None:
    """Save ez-Q compatible wave/seq artifacts alongside the existing board dumps."""
    out_dir.mkdir(parents=True, exist_ok=True)
    bundle_meta: dict[str, Any] = {
        "mode": metadata.get("mode", "ezq"),
        "layout": metadata.get("layout", host.DEFAULT_DDR_LAYOUT),
        "sample_rate_hz": metadata.get("sample_rate_hz"),
        "axis_freq_hz": metadata.get("axis_freq_hz"),
        "rfdc_interpolation": metadata.get("rfdc_interpolation"),
        "analog_sample_rate_hz": metadata.get("analog_sample_rate_hz"),
        "encoding": "ezq-compatible",
        "channel_format": channel_format,
        "channels": [],
    }
    for key in ("ezq", "tile_bytes", "superblock_bytes", "beat_bytes", "lane_bytes", "lanes"):
        if key in metadata:
            bundle_meta[key] = metadata[key]
    for channel, wave in sorted(channel_waves.items()):
        interleaved = ezq_wave_to_interleaved_int16(wave, wave_format=channel_format)
        packed = ezq_wave_to_packed_int32(wave, wave_format=channel_format)
        iq_matrix = interleaved.reshape(-1, 2).T
        seq_rows = None
        if channel_sequences is not None and channel in channel_sequences:
            seq_rows = ezq_sequence_rows(channel_sequences[channel])
        else:
            delay_cycles = int(metadata.get(f"ch{channel}_delay_cycles", 0))
            seq_rows = np.array([
                [0, packed.size >> 1, delay_cycles, 4 << 11],  # DL
                [0, packed.size >> 1, 0, 0x0000],              # DI
                [0, 0, 0, 0x8000],                              # ST
            ], dtype="<u2")
        np.save(out_dir / f"ch{channel}_{stem}_wave_iq.npy", iq_matrix)
        np.save(out_dir / f"ch{channel}_{stem}_wave_packed.npy", packed)
        np.save(out_dir / f"ch{channel}_{stem}_seq.npy", seq_rows)
        host.RFSocController._save_hex_text(interleaved.astype("<i2").tobytes(), str(out_dir / f"ch{channel}_{stem}_wave_hex.txt"))
        channel_meta = dict(metadata.get(f"ch{channel}", {})) if isinstance(metadata.get(f"ch{channel}"), dict) else {}
        channel_meta.update({
            "channel": channel,
            "wave_iq_npy": f"ch{channel}_{stem}_wave_iq.npy",
            "wave_packed_npy": f"ch{channel}_{stem}_wave_packed.npy",
            "seq_npy": f"ch{channel}_{stem}_seq.npy",
            "samples_per_channel": int(interleaved.size),
            "complex_samples": int(interleaved.size // 2),
            "bytes_per_channel": int(interleaved.size * 2),
            "delay_cycles": int(metadata.get(f"ch{channel}_delay_cycles", _ezq_sequence_delay_cycles(seq_rows))),
            "flags": ezq_sequence_flags(seq_rows),
        })
        bundle_meta["channels"].append(channel_meta)
    (out_dir / f"{stem}_metadata.json").write_text(json.dumps(bundle_meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def load_ezq_channel_wave(
    path: Path,
    wave_format: Literal["iq_matrix", "packed_iq", "interleaved_iq"] = "packed_iq",
) -> np.ndarray:
    """Load an ez-Q channel wave artifact and normalize it to interleaved int16 lanes."""
    wave = np.load(path, allow_pickle=False)
    return ezq_wave_to_interleaved_int16(wave, wave_format=wave_format)


def build_ezq_upload_plan(
    channel_waves: dict[int, np.ndarray | list],
    channel_sequences: dict[int, np.ndarray | list] | None = None,
    layout: str = host.DEFAULT_DDR_LAYOUT,
    auto_start: bool = True,
    loop: bool = False,
    channel_format: Literal["iq_matrix", "packed_iq", "interleaved_iq"] = "interleaved_iq",
) -> tuple[dict[int, np.ndarray], list[list[int]], dict[int, int]]:
    """Convert ez-Q style channel wave/seq data into the current RFSoC upload plan."""
    if layout not in {host.DDR_LAYOUT_CONTIGUOUS, host.DDR_LAYOUT_TILED, host.DDR_LAYOUT_INTERLEAVED_512B}:
        raise ValueError(f"unsupported DDR layout: {layout}")
    normalized: dict[int, np.ndarray] = {}
    delays: dict[int, int] = {}
    addrs: dict[int, int] = {}
    lengths: dict[int, int] = {}
    for channel, wave in sorted(channel_waves.items()):
        interleaved = ezq_wave_to_interleaved_int16(wave, wave_format=channel_format)
        normalized[channel] = interleaved
        if layout == host.DDR_LAYOUT_INTERLEAVED_512B:
            addrs[channel] = 0
        elif layout == host.DDR_LAYOUT_TILED:
            addrs[channel] = host.tiled_channel_base_addr(channel)
        else:
            addrs[channel] = host.DDR_CH_ADDR[channel - 1]
        lengths[channel] = waveform_length_bytes(interleaved)
        if channel_sequences is not None and channel in channel_sequences:
            delays[channel] = _ezq_sequence_delay_cycles(channel_sequences[channel], default=0)
        else:
            delays[channel] = 0
    commands = build_play_commands(
        loop=loop,
        auto_start=auto_start,
        channel_addrs=addrs,
        channel_lengths=lengths,
        channel_delays=delays,
        layout=layout,
    )
    return normalized, commands, delays


def build_metadata(
    mode: str,
    sample_rate_hz: float,
    encoding: str,
    loop: bool,
    x_freq_hz: float | None = None,
    y_freq_hz: float | None = None,
    layout: str = host.DEFAULT_DDR_LAYOUT,
    **extra: Any,
) -> dict[str, Any]:
    if layout not in {host.DDR_LAYOUT_CONTIGUOUS, host.DDR_LAYOUT_TILED, host.DDR_LAYOUT_INTERLEAVED_512B}:
        raise ValueError(f"unsupported DDR layout: {layout}")
    if layout == host.DDR_LAYOUT_INTERLEAVED_512B:
        channel_addrs = DEFAULT_INTERLEAVED_CHANNEL_ADDRS
    elif layout == host.DDR_LAYOUT_TILED:
        channel_addrs = DEFAULT_TILED_CHANNEL_ADDRS
    else:
        channel_addrs = DEFAULT_CHANNEL_ADDRS
    record_duration_s = host.NUM_SAMPLES / float(sample_rate_hz)
    metadata: dict[str, Any] = {
        "mode": mode,
        "sample_format": "16-bit little-endian raw DAC codes",
        "encoding": encoding,
        "sample_rate_hz": float(sample_rate_hz),
        "rfdc_interpolation": int(host.RFDC_INTERPOLATION),
        "analog_sample_rate_hz": float(sample_rate_hz) * int(host.RFDC_INTERPOLATION),
        "dac_fs_hz": float(host.DAC_TILE_FS),
        "axis_hz": float(host.DAC_FABRIC_HZ),
        "record_duration_s": record_duration_s,
        "samples_per_channel": int(host.NUM_SAMPLES),
        "bytes_per_channel": int(host.FIXED_DATA_BYTES),
        "layout": layout,
        "tile_bytes": int(host.DDR_TILE_BYTES),
        "superblock_bytes": int(host.DDR_SUPERBLOCK_BYTES),
        "beat_bytes": int(host.DDR_INTERLEAVED_BEAT_BYTES if layout == host.DDR_LAYOUT_INTERLEAVED_512B else host.BEAT_BYTES),
        "lane_bytes": int(host.DDR_INTERLEAVED_LANE_BYTES),
        "lanes": int(host.DDR_INTERLEAVED_CHANNELS),
        "x_ddr_offset": f"0x{channel_addrs[1]:016X}",
        "y_ddr_offset": f"0x{channel_addrs[2]:016X}",
        "loop": bool(loop),
    }
    for channel, ddr_addr in channel_addrs.items():
        metadata[f"ch{channel}_ddr_offset"] = f"0x{ddr_addr:016X}"
        metadata[f"ch{channel}_logical_bytes"] = int(host.FIXED_DATA_BYTES)
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
    layout: str = host.DEFAULT_DDR_LAYOUT,
    rfdc_nco_hz: dict[int, float] | dict[str, float] | None = None,
    rfdc_nyquist_zones: dict[int, int] | dict[str, int] | None = None,
    preflight_ack: bool = True,
    instruction_repeats: int = 3,
    enabled_channels: set[int] | list[int] | tuple[int, ...] | None = None,
) -> None:
    if layout not in {host.DDR_LAYOUT_CONTIGUOUS, host.DDR_LAYOUT_TILED, host.DDR_LAYOUT_INTERLEAVED_512B}:
        raise ValueError(f"unsupported DDR layout: {layout}")
    ctrl = host.RFSocController(
        ip,
        port=port,
        transport="udp",
        udp_interface=udp_interface,
        udp_source_ip=udp_source_ip,
        timeout_s=timeout_s,
    )
    if layout == host.DDR_LAYOUT_INTERLEAVED_512B:
        default_addrs = DEFAULT_INTERLEAVED_CHANNEL_ADDRS
    elif layout == host.DDR_LAYOUT_TILED:
        default_addrs = DEFAULT_TILED_CHANNEL_ADDRS
    else:
        default_addrs = DEFAULT_CHANNEL_ADDRS
    enabled = None if enabled_channels is None else {int(channel) for channel in enabled_channels}
    if enabled is not None and not enabled:
        raise ValueError("enabled_channels must not be empty")
    available: dict[int, np.ndarray] = {1: x, 2: y}
    if ch3 is not None:
        available[3] = ch3
    if ch4 is not None:
        available[4] = ch4
    if extra_channels is not None:
        for channel, samples in sorted(extra_channels.items()):
            available[int(channel)] = samples
    missing = sorted(enabled - set(available)) if enabled is not None else []
    if missing:
        raise ValueError(f"enabled channel data is missing for CH{', CH'.join(str(channel) for channel in missing)}")
    uploads: list[tuple[int, np.ndarray, int, str]] = []
    for channel, samples in sorted(available.items()):
        if enabled is not None and channel not in enabled:
            continue
        uploads.append((channel, samples, default_addrs[channel], f"ch{channel}_upload_hex.txt"))
    if not uploads:
        raise ValueError("no channels selected for upload/playback")

    try:
        if preflight_ack and getattr(ctrl, "transport", "udp") == "udp":
            warm_control = getattr(ctrl, "warm_udp_control_path", None)
            if warm_control is None:
                ctrl.rvctrl1_ping(wait_response=True)
            else:
                warm_control()
        if layout == host.DDR_LAYOUT_INTERLEAVED_512B:
            channel_waves = {channel: samples for channel, samples, _, _ in uploads}
            upload_interleaved = getattr(ctrl, "upload_waveform_udp_interleaved", None)
            if upload_interleaved is not None:
                upload_interleaved(channel_waves, host.DDR_BASE, str(output_dir / "interleaved_wave_hex.txt"))
            else:
                upload_interleaved = getattr(ctrl, "upload_waveform_interleaved", None)
                if upload_interleaved is not None:
                    upload_interleaved(channel_waves, host.DDR_BASE, str(output_dir / "interleaved_wave_hex.txt"))
                else:
                    payload_bytes, _ = host.pack_interleaved_512b_waveforms(channel_waves)
                    ctrl.upload_waveform_udp(
                        np.frombuffer(payload_bytes, dtype="<i2"),
                        host.DDR_BASE,
                        str(output_dir / "interleaved_wave_hex.txt"),
                    )
        else:
            for channel, samples, ddr_addr, filename in uploads:
                if layout == host.DDR_LAYOUT_TILED:
                    ctrl.upload_waveform_udp_tiled(samples, channel, host.DDR_BASE, str(output_dir / filename))
                else:
                    ctrl.upload_waveform_udp(samples, ddr_addr, str(output_dir / filename))
        if rfdc_nco_hz is not None and rfdc_nyquist_zones is not None:
            upload_mailbox = getattr(ctrl, "upload_rfdc_nco_mailbox", None)
            if upload_mailbox is None:
                raise RuntimeError("RFSocController does not support RFDC NCO mailbox upload")
            upload_mailbox(rfdc_nco_hz, rfdc_nyquist_zones)
        if post_upload_sleep_s > 0:
            time.sleep(post_upload_sleep_s)
        channel_addrs = {channel: 0 for channel, _, _, _ in uploads} if layout == host.DDR_LAYOUT_INTERLEAVED_512B else {channel: ddr_addr for channel, _, ddr_addr, _ in uploads}
        channel_lengths = {channel: waveform_length_bytes(samples) for channel, samples, _, _ in uploads}
        commands = build_play_commands(
            loop=loop,
            auto_start=auto_start,
            channel_addrs=None if layout == host.DDR_LAYOUT_INTERLEAVED_512B else channel_addrs,
            channel_lengths=channel_lengths,
            channel_delays=channel_delays,
            enabled_channels=[channel for channel, _, _, _ in uploads],
            layout=layout,
        )
        repeats = max(1, int(instruction_repeats))
        for repeat_index in range(repeats):
            ctrl.send_instructions(commands)
            if repeat_index + 1 < repeats:
                time.sleep(0.002)
    finally:
        ctrl.close()
