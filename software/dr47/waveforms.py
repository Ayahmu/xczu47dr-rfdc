"""Waveform conversion and current 512-bit DDR upload layout."""

from __future__ import annotations

import struct
from typing import Any, Literal, Mapping

import numpy as np

from .errors import ParameterRangeError, UnsupportedSequenceError, WaveformFormatError
from .protocol import (
    BEAT_BYTES,
    CHANNEL_ROLES,
    DDR_BASE,
    DDR_INTERLEAVED_BEAT_BYTES,
    DDR_INTERLEAVED_CHANNELS,
    DDR_INTERLEAVED_LANE_BYTES,
    DDR_MAX_BYTES_PER_CHANNEL,
    DDR_SUPERBLOCK_BYTES,
    DDR_TILE_BYTES,
    DDR_TILE_CHANNELS,
    PLAY_FLAG_INTERLEAVED,
    PLAY_FLAG_LOOP,
    PLAY_FLAG_TILED,
    UDP_WAVE_BULK_MAGIC,
    UDP_WAVE_DDR_MAGIC,
    UDP_WAVE_INSTR_MAGIC,
    align_bytes_to_beat,
    require_beat_aligned,
    validate_udp_bulk_beats,
)

DEFAULT_DDR_LAYOUT = "interleaved_512b"
DDR_LAYOUT_CONTIGUOUS = "contiguous"
DDR_LAYOUT_TILED = "tiled"
DDR_LAYOUT_INTERLEAVED_512B = DEFAULT_DDR_LAYOUT
DAC_TILE_FS = 6.4e9
DAC_INTERP = 16
DAC_IQ_SAMPLE_RATE_HZ = DAC_TILE_FS / DAC_INTERP
DAC_FABRIC_HZ = DAC_IQ_SAMPLE_RATE_HZ / 8
DEFAULT_WAVEFORM_SAMPLE_RATE_HZ = DAC_IQ_SAMPLE_RATE_HZ
DEFAULT_AXIS_HZ = DAC_FABRIC_HZ
RFDC_INTERPOLATION = DAC_INTERP
BEAT_SAMPLES = BEAT_BYTES // 2
NUM_SAMPLES = 4096 // 2
INT16_PER_DACWORD = 16
INT16_PER_BEAT = INT16_PER_DACWORD


def iq_duration_to_interleaved_sample_count(duration_s: float, sample_rate_hz: float) -> int:
    """Return an aligned raw-int16 count for a finite complex-IQ record.

    This is the record sizing contract used by the web manual-channel path:
    the requested duration is rounded to a whole complex sample and then up to
    one 256-bit DAC word (16 int16 lanes / 8 I/Q samples).
    """

    if float(duration_s) <= 0.0:
        raise ParameterRangeError("duration_s must be positive")
    if float(sample_rate_hz) <= 0.0:
        raise ParameterRangeError("sample_rate_hz must be positive")
    complex_samples = max(1, int(round(float(duration_s) * float(sample_rate_hz))))
    return ((complex_samples * 2 + INT16_PER_DACWORD - 1) // INT16_PER_DACWORD) * INT16_PER_DACWORD


def _pack_iq_interleaved(i_wave: np.ndarray, q_wave: np.ndarray, sample_count: int) -> np.ndarray:
    if int(sample_count) % INT16_PER_DACWORD:
        raise ParameterRangeError("sample_count must be a whole 256-bit DAC word")
    complex_samples = int(sample_count) // 2
    i_data = _normalize_int16(i_wave, complex_samples)
    q_data = _normalize_int16(q_wave, complex_samples)
    packed = np.empty(int(sample_count), dtype=np.int16)
    packed[0::2] = i_data
    packed[1::2] = q_data
    return packed


def make_iq_sine_interleaved(
    frequency_hz: float,
    phase_rad: float,
    amplitude: int,
    sample_rate_hz: float,
    *,
    sample_count: int,
    q_sign: int = -1,
) -> np.ndarray:
    """Build the web manual-path IQ sine format: ``I0,Q0,...`` int16."""

    if int(q_sign) not in (-1, 1):
        raise ParameterRangeError("q_sign must be +1 or -1")
    if abs(float(frequency_hz)) > float(sample_rate_hz) / 2.0:
        raise ParameterRangeError("IQ frequency exceeds the complex-sample Nyquist limit")
    count = int(sample_count) // 2
    sample_index = np.arange(count, dtype=np.float64)
    angle = (2.0 * np.pi * float(frequency_hz) * sample_index / float(sample_rate_hz)) + float(phase_rad)
    scale = float(amplitude)
    return _pack_iq_interleaved(
        np.round(np.clip(np.cos(angle) * scale, -32767.0, 32767.0)).astype(np.int16),
        np.round(np.clip(int(q_sign) * np.sin(angle) * scale, -32767.0, 32767.0)).astype(np.int16),
        int(sample_count),
    )


def make_iq_gaussian_sine_interleaved(
    frequency_hz: float,
    phase_rad: float,
    amplitude: int,
    sample_rate_hz: float,
    duration_s: float,
    *,
    sample_count: int | None = None,
    fwhm_s: float | None = None,
    q_sign: int = -1,
    hls_xy_drag: bool = False,
    drag_alpha: float = 0.5,
    drag_delta_hz: float = -200e6,
) -> np.ndarray:
    """Build the web manual-path XY Gaussian IQ waveform exactly.

    The web's manual ``xy`` control uses ``FWHM=duration/2`` and has its
    HLS-DRAG option disabled.  The optional DRAG arguments expose the explicit
    derivative-quadrature variant for callers that need it.
    """

    if int(q_sign) not in (-1, 1):
        raise ParameterRangeError("q_sign must be +1 or -1")
    if abs(float(frequency_hz)) > float(sample_rate_hz) / 2.0:
        raise ParameterRangeError("IQ frequency exceeds the complex-sample Nyquist limit")
    if sample_count is None:
        sample_count = iq_duration_to_interleaved_sample_count(duration_s, sample_rate_hz)
    if int(sample_count) % INT16_PER_DACWORD:
        raise ParameterRangeError("sample_count must be a whole 256-bit DAC word")
    if hls_xy_drag and abs(float(drag_delta_hz)) < 1.0:
        raise ParameterRangeError("drag_delta_hz must be non-zero when HLS DRAG is enabled")

    count = int(sample_count) // 2
    time_s = np.arange(count, dtype=np.float64) / float(sample_rate_hz)
    duration = float(duration_s)
    fwhm = float(fwhm_s) if fwhm_s is not None else duration / 2.0
    sigma = max(fwhm / 2.3548200, 1.0 / float(sample_rate_hz))
    envelope = np.exp(-0.5 * ((time_s - duration / 2.0) / sigma) ** 2)
    if hls_xy_drag:
        envelope_dt = envelope * (-(time_s - duration / 2.0) / (sigma * sigma))
        quadrature = float(drag_alpha) * envelope_dt / (2.0 * np.pi * float(drag_delta_hz))
    else:
        quadrature = np.zeros_like(envelope)
    angle = (2.0 * np.pi * float(frequency_hz) * time_s) + float(phase_rad)
    wave = (envelope + 1j * quadrature) * np.exp(1j * int(q_sign) * angle) * float(amplitude)
    return _pack_iq_interleaved(
        np.round(np.clip(np.real(wave), -32767.0, 32767.0)).astype(np.int16),
        np.round(np.clip(np.imag(wave), -32767.0, 32767.0)).astype(np.int16),
        int(sample_count),
    )


def place_interleaved_iq_in_record(
    active_wave: np.ndarray | list,
    *,
    delay_s: float,
    record_duration_s: float,
    sample_rate_hz: float,
) -> np.ndarray:
    """Place an active IQ waveform in an aligned, zero-filled web record."""

    active = np.asarray(active_wave, dtype=np.int16).reshape(-1)
    if active.size % 2:
        raise WaveformFormatError("active IQ waveform must contain whole I/Q samples")
    record_count = iq_duration_to_interleaved_sample_count(record_duration_s, sample_rate_hz)
    start = max(0, int(round(float(delay_s) * float(sample_rate_hz)))) * 2
    end = start + int(active.size)
    if end > record_count:
        raise ParameterRangeError(
            f"pulse end {(end / 2.0 / float(sample_rate_hz)) * 1e9:g} ns exceeds "
            f"record {(record_count / 2.0 / float(sample_rate_hz)) * 1e9:g} ns"
        )
    record = np.zeros(record_count, dtype=np.int16)
    record[start:end] = active
    return record


def waveform_bytes(wave: np.ndarray | list) -> bytes:
    return np.ascontiguousarray(wave, dtype="<i2").tobytes()


def _normalize_int16(samples: np.ndarray | list, sample_count: int | None = None) -> np.ndarray:
    arr = np.asarray(samples, dtype=np.int16).reshape(-1)
    if sample_count is None:
        return arr.copy()
    count = int(sample_count)
    if count < 0:
        raise ParameterRangeError("sample_count must be non-negative")
    if arr.size >= count:
        return arr[:count].copy()
    return np.pad(arr, (0, count - arr.size), mode="constant")


def ezq_wave_to_interleaved_int16(
    wave: np.ndarray | list,
    wave_format: Literal["iq_matrix", "packed_iq", "interleaved_iq", "z", "real"] = "packed_iq",
) -> np.ndarray:
    """Convert ez-Q IQ/real forms into little-endian ``I0,Q0,I1,Q1`` lanes."""
    arr = np.asarray(wave)
    try:
        if wave_format in {"iq_matrix", "iq", "matrix"}:
            if arr.ndim != 2:
                raise WaveformFormatError("iq_matrix wave must be 2-D with row/column I and Q")
            if arr.shape[0] == 2:
                i_data, q_data = arr[0], arr[1]
            elif arr.shape[1] == 2:
                i_data, q_data = arr[:, 0], arr[:, 1]
            else:
                raise WaveformFormatError("iq_matrix wave must have exactly two I/Q axes")
            i_data = np.ascontiguousarray(i_data, dtype="<i2").reshape(-1)
            q_data = np.ascontiguousarray(q_data, dtype="<i2").reshape(-1)
            if i_data.size != q_data.size:
                raise WaveformFormatError("I and Q vectors must have the same length")
            out = np.empty(i_data.size * 2, dtype=np.int16)
            out[0::2], out[1::2] = i_data, q_data
            return out
        if wave_format in {"packed_iq", "packed"}:
            packed = np.ascontiguousarray(arr, dtype="<i4").reshape(-1)
            return packed.view("<i2").copy()
        if wave_format in {"interleaved_iq", "interleaved", "iq_interleaved"}:
            interleaved = np.ascontiguousarray(arr, dtype="<i2").reshape(-1)
            if interleaved.size % 2:
                raise WaveformFormatError("interleaved_iq wave must contain an even number of int16 lanes")
            return interleaved.copy()
        if wave_format in {"z", "real", "z_real"}:
            real = np.ascontiguousarray(arr, dtype="<i2").reshape(-1)
            out = np.zeros(real.size * 2, dtype=np.int16)
            out[0::2] = real
            return out
    except (TypeError, ValueError, OverflowError) as exc:
        if isinstance(exc, WaveformFormatError):
            raise
        raise WaveformFormatError(f"cannot convert {wave_format} waveform: {exc}") from exc
    raise WaveformFormatError(f"unsupported waveform format: {wave_format}")


def ezq_wave_to_packed_int32(
    wave: np.ndarray | list,
    wave_format: Literal["iq_matrix", "packed_iq", "interleaved_iq", "z", "real"] = "packed_iq",
) -> np.ndarray:
    if wave_format in {"packed_iq", "packed"}:
        return np.ascontiguousarray(np.asarray(wave), dtype="<i4").reshape(-1)
    interleaved = ezq_wave_to_interleaved_int16(wave, wave_format=wave_format)
    i_data = interleaved[0::2].astype(np.int32)
    q_data = interleaved[1::2].astype(np.int32)
    return ((q_data & 0xFFFF) << 16) | (i_data & 0xFFFF)


def waveform_length_bytes(samples: np.ndarray | list) -> int:
    return align_bytes_to_beat(np.asarray(samples).size * 2)


def tiled_ddr_addr(channel: int, byte_offset: int, base_addr: int = DDR_BASE) -> int:
    channel_index = int(channel) - 1
    if not 0 <= channel_index < DDR_TILE_CHANNELS:
        raise ParameterRangeError("channel must be in 1..8")
    require_beat_aligned(base_addr, "base_addr")
    require_beat_aligned(byte_offset, "byte_offset")
    tile_index, intra = divmod(int(byte_offset), DDR_TILE_BYTES)
    return int(base_addr) + tile_index * DDR_SUPERBLOCK_BYTES + channel_index * DDR_TILE_BYTES + intra


def tiled_channel_base_addr(channel: int, base_addr: int = DDR_BASE) -> int:
    return tiled_ddr_addr(channel, 0, base_addr)


def interleaved_ddr_addr(channel: int, byte_offset: int, base_addr: int = DDR_BASE) -> int:
    channel_index = int(channel) - 1
    if not 0 <= channel_index < DDR_INTERLEAVED_CHANNELS:
        raise ParameterRangeError("channel must be in 1..8")
    if int(byte_offset) < 0 or int(byte_offset) % DDR_INTERLEAVED_LANE_BYTES:
        raise ParameterRangeError("byte_offset must be non-negative and 8B aligned")
    require_beat_aligned(base_addr, "base_addr")
    return int(base_addr) + (int(byte_offset) // DDR_INTERLEAVED_LANE_BYTES) * DDR_INTERLEAVED_BEAT_BYTES + channel_index * DDR_INTERLEAVED_LANE_BYTES


def interleaved_channel_lane_addr(channel: int, base_addr: int = DDR_BASE) -> int:
    return interleaved_ddr_addr(channel, 0, base_addr)


def iter_udp_waveform_packets(
    wave_bytes: bytes | np.ndarray,
    ddr_addr: int,
    sample_count: int | None = None,
):
    if isinstance(wave_bytes, np.ndarray):
        samples = _normalize_int16(wave_bytes, sample_count)
        payload = waveform_bytes(samples)
    else:
        payload = bytes(wave_bytes)
    payload += b"\x00" * ((-len(payload)) % BEAT_BYTES)
    base = require_beat_aligned(ddr_addr, "ddr_addr") & 0xFFFFFFFFFFFFFFFF
    for offset in range(0, len(payload), BEAT_BYTES):
        words = struct.unpack_from("<QQQQ", payload, offset)
        yield struct.pack("<QQQQQQ", UDP_WAVE_DDR_MAGIC, base + offset, *words)


def iter_tiled_udp_waveform_packets(
    wave_bytes: bytes | np.ndarray,
    channel: int,
    base_addr: int = DDR_BASE,
    sample_count: int | None = None,
):
    if isinstance(wave_bytes, np.ndarray):
        payload = waveform_bytes(_normalize_int16(wave_bytes, sample_count))
    else:
        payload = bytes(wave_bytes)
    payload += b"\x00" * ((-len(payload)) % BEAT_BYTES)
    for offset in range(0, len(payload), BEAT_BYTES):
        words = struct.unpack_from("<QQQQ", payload, offset)
        yield struct.pack("<QQQQQQ", UDP_WAVE_DDR_MAGIC, tiled_ddr_addr(channel, offset, base_addr), *words)


def pack_interleaved_512b_waveforms(channel_waves: Mapping[int, np.ndarray | list]) -> tuple[bytes, int]:
    """Pack eight channel-local streams into 512-bit ``CH1..CH8`` lanes."""
    if not channel_waves:
        return b"", 0
    normalized: dict[int, np.ndarray] = {}
    max_samples = 0
    for channel in range(1, DDR_INTERLEAVED_CHANNELS + 1):
        wave = channel_waves.get(channel)
        arr = np.asarray(wave, dtype=np.int16).reshape(-1) if wave is not None else np.zeros(0, dtype=np.int16)
        normalized[channel] = arr
        max_samples = max(max_samples, int(arr.size))
    max_samples = align_bytes_to_beat(max_samples * 2) // 2
    packed = {
        channel: np.pad(normalized[channel][:max_samples], (0, max(0, max_samples - normalized[channel].size)), mode="constant").astype("<i2", copy=False).tobytes()
        for channel in range(1, DDR_INTERLEAVED_CHANNELS + 1)
    }
    beat_count = max_samples // 4
    image = bytearray(beat_count * DDR_INTERLEAVED_BEAT_BYTES)
    for beat_index in range(beat_count):
        for channel in range(1, DDR_INTERLEAVED_CHANNELS + 1):
            start = beat_index * DDR_INTERLEAVED_LANE_BYTES
            image[beat_index * DDR_INTERLEAVED_BEAT_BYTES + (channel - 1) * DDR_INTERLEAVED_LANE_BYTES: beat_index * DDR_INTERLEAVED_BEAT_BYTES + channel * DDR_INTERLEAVED_LANE_BYTES] = packed[channel][start:start + DDR_INTERLEAVED_LANE_BYTES]
    return bytes(image), max_samples


def iter_interleaved_udp_waveform_packets(channel_waves: Mapping[int, np.ndarray | list], base_addr: int = DDR_BASE):
    payload, _ = pack_interleaved_512b_waveforms(channel_waves)
    for offset in range(0, len(payload), BEAT_BYTES):
        words = struct.unpack_from("<QQQQ", payload, offset)
        yield struct.pack("<QQQQQQ", UDP_WAVE_DDR_MAGIC, int(base_addr) + offset, *words)


def ezq_sequence_rows(sequence: np.ndarray | list) -> np.ndarray:
    rows = np.asarray(sequence, dtype="<u2")
    if rows.size == 0:
        return rows.reshape(0, 4)
    if rows.ndim == 1:
        if rows.size % 4:
            raise WaveformFormatError("flat ez-Q seq must contain a multiple of 4 words")
        return rows.reshape(-1, 4)
    if rows.ndim == 2 and rows.shape[1] == 4:
        return np.ascontiguousarray(rows, dtype="<u2")
    raise WaveformFormatError("ez-Q seq must be a flat 4-word list or an (n, 4) array")


def ezq_sequence_flags(sequence: np.ndarray | list) -> dict[str, bool]:
    rows = ezq_sequence_rows(sequence)
    funcs = ((rows[:, 3] >> 11) & 0xF).tolist() if rows.size else []
    return {
        "has_trigger": 8 in funcs,
        "has_loop_start": 1 in funcs,
        "has_loop_end": 2 in funcs,
        "has_delay": 4 in funcs,
        "has_stop": any(bool(x) for x in ((rows[:, 3] >> 15) & 1).tolist()) if rows.size else False,
    }


def pack_udp_instruction_packet(commands: list[list[int] | tuple[int, ...]]) -> bytes:
    if not commands:
        raise WaveformFormatError("instruction packet must contain at least one command")
    data = bytearray()
    for command in commands:
        if len(command) < 4:
            raise WaveformFormatError("each instruction must contain op, channel, value and address")
        op, channel, value, address = map(int, command[:4])
        flags = int(command[4]) if len(command) > 4 else 0
        if op == 2:
            require_beat_aligned(value, "PLAY length")
            require_beat_aligned(address, "PLAY addr")
        word0 = (channel & 0xF) << 4 | (op & 0xF) | ((flags & 0x7) << 8)
        data += struct.pack("<IIII", word0, value & 0xFFFFFFFF, address & 0xFFFFFFFF, (address >> 32) & 0xFFFFFFFF)
    return struct.pack("<QQ", UDP_WAVE_INSTR_MAGIC, len(data) // 8) + data


def sequence_to_play_commands(
    sequence: np.ndarray | list,
    *,
    channel: int,
    wave_format: str = "packed_iq",
    base_addr: int = DDR_BASE,
) -> tuple[list[list[int]], dict[str, Any]]:
    """Translate supported ez-Q rows into the current three-op executor.

    The current PL has no instruction-level conditional/jump engine.  A loop
    spanning the complete sequence is represented by the executor's END loop
    flag; all other nested or partial loops are rejected explicitly.
    """
    rows = ezq_sequence_rows(sequence)
    if not 1 <= int(channel) <= 8:
        raise ParameterRangeError("channel must be in 1..8")
    # Every uploaded channel is represented as an I/Q pair in the current
    # RFDC DDR image.  A Z real sample therefore becomes I=value,Q=0 and still
    # occupies four bytes.
    sample_bytes = 4
    commands: list[list[int]] = []
    waits_for_trigger = False
    loop_starts: list[int] = []
    loop_ends: list[int] = []
    loop_command_start: int | None = None
    loop_count = 0
    infinite_loop = False
    for index, row in enumerate(rows.tolist()):
        address_units, length_units, count, control = (int(item) for item in row)
        # The stop bit terminates the ez-Q program; it is represented by the
        # WAVEINS0 END command below rather than a zero-length PLAY.
        if control & 0x8000:
            break
        func = (control >> 11) & 0xF
        level = (control >> 8) & 0x3
        has_trigger = bool((control >> 10) & 1)
        if has_trigger:
            waits_for_trigger = True
        if func == 0:  # direct play
            length = align_bytes_to_beat(length_units * sample_bytes)
            addr = int(base_addr) + address_units * sample_bytes
            commands.append([2, int(channel), length, addr, PLAY_FLAG_INTERLEAVED])
        elif func == 4:  # delay
            commands.append([1, int(channel), max(0, count), 0])
        elif func == 8:  # external trigger: END auto-start is the hardware equivalent
            waits_for_trigger = True
        elif func == 1:
            loop_starts.append(index)
            if level != 0:
                raise UnsupportedSequenceError("nested ez-Q loops are not supported by WAVEINS0")
            if loop_command_start is not None:
                raise UnsupportedSequenceError("nested ez-Q loops are not supported by WAVEINS0")
            loop_command_start = len(commands)
            loop_count = count
            if loop_count <= 0:
                infinite_loop = True
        elif func == 2:
            loop_ends.append(index)
            if level != 0:
                raise UnsupportedSequenceError("nested ez-Q loops are not supported by WAVEINS0")
            if loop_command_start is None:
                raise UnsupportedSequenceError("ez-Q loop end has no matching loop start")
            if not infinite_loop:
                if loop_count > 1024:
                    raise UnsupportedSequenceError("finite ez-Q loop counts above 1024 are not supported")
                body = commands[loop_command_start:]
                if loop_count > 1:
                    commands.extend(body * (loop_count - 1))
            loop_command_start = None
        elif func == 15 and (control & 0x8000):
            pass
        elif func == 0 and (control & 0x8000):
            pass
        else:
            raise UnsupportedSequenceError(
                f"ez-Q sequence instruction func={func} at row {index} is not supported"
            )
        if control & 0x8000:
            break
    if loop_starts or loop_ends:
        if len(loop_starts) != 1 or len(loop_ends) != 1 or loop_starts[0] >= loop_ends[0]:
            raise UnsupportedSequenceError("only one complete top-level ez-Q loop is supported")
    commands.append([3, 15 if waits_for_trigger is False else 0, 0, 0, PLAY_FLAG_LOOP if infinite_loop else 0])
    return commands, {
        "wait_for_trigger": waits_for_trigger,
        "loop": bool(infinite_loop),
        "loop_count": loop_count if loop_starts else 1,
        "rows": rows,
    }


def iter_max_length_udp_batches(
    bytes_per_channel: int,
    base_addr: int = DDR_BASE,
    beats_per_datagram: int = 4,
    **_: Any,
):
    """Yield deterministic zero-filled bulk packets for max-length testing."""
    per_channel = require_beat_aligned(bytes_per_channel, "bytes_per_channel")
    if per_channel <= 0 or per_channel > DDR_MAX_BYTES_PER_CHANNEL:
        raise ParameterRangeError(f"bytes_per_channel must be in [32, {DDR_MAX_BYTES_PER_CHANNEL}], got {per_channel}")
    beats = validate_udp_bulk_beats(beats_per_datagram)
    total_bytes = per_channel * DDR_INTERLEAVED_CHANNELS
    chunk = beats * DDR_INTERLEAVED_BEAT_BYTES
    for offset in range(0, total_bytes, chunk):
        payload = bytes(min(chunk, total_bytes - offset))
        yield struct.pack("<QQQ", UDP_WAVE_BULK_MAGIC, int(base_addr) + offset, len(payload) // 8) + payload


__all__ = [name for name in globals() if not name.startswith("_")]
