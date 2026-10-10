"""Waveform conversion and current 512-bit DDR upload layout."""

from __future__ import annotations

import math
import struct
from typing import Any, Literal, Mapping

import numpy as np

from .errors import ParameterRangeError, WaveformFormatError
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
    UDP_WAVE_BULK_MAGIC,
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
# Largest I/Q sample magnitude the waveform helpers emit (symmetric int16).
_INT16_FULL_SCALE = 32767.0


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


def _amplitude_to_codes(amplitude: float) -> float:
    """Convert a normalized amplitude in [-1, 1] to int16 DAC codes (1 = full scale)."""

    value = float(amplitude)
    if not math.isfinite(value) or abs(value) > 1.0:
        raise ParameterRangeError(
            f"amplitude must be a normalized value in [-1, 1] (1 = full scale), got {amplitude!r}"
        )
    return value * _INT16_FULL_SCALE


def make_iq_sine_interleaved(
    frequency_hz: float,
    phase_rad: float,
    amplitude: float,
    sample_rate_hz: float,
    *,
    sample_count: int,
    q_sign: int = -1,
) -> np.ndarray:
    """Build the web manual-path IQ sine format: ``I0,Q0,...`` int16.

    ``amplitude`` is normalized to [-1, 1]; 1 is the int16 full scale (32767).
    """

    return _iq_sine_codes(frequency_hz, phase_rad, _amplitude_to_codes(amplitude), sample_rate_hz,
                          sample_count=sample_count, q_sign=q_sign)


def _iq_sine_codes(
    frequency_hz: float,
    phase_rad: float,
    amplitude_codes: float,
    sample_rate_hz: float,
    *,
    sample_count: int,
    q_sign: int = -1,
) -> np.ndarray:
    """``make_iq_sine_interleaved`` with the amplitude given in int16 DAC codes."""

    if int(q_sign) not in (-1, 1):
        raise ParameterRangeError("q_sign must be +1 or -1")
    if abs(float(frequency_hz)) > float(sample_rate_hz) / 2.0:
        raise ParameterRangeError("IQ frequency exceeds the complex-sample Nyquist limit")
    count = int(sample_count) // 2
    sample_index = np.arange(count, dtype=np.float64)
    angle = (2.0 * np.pi * float(frequency_hz) * sample_index / float(sample_rate_hz)) + float(phase_rad)
    scale = float(amplitude_codes)
    return _pack_iq_interleaved(
        np.round(np.clip(np.cos(angle) * scale, -32767.0, 32767.0)).astype(np.int16),
        np.round(np.clip(int(q_sign) * np.sin(angle) * scale, -32767.0, 32767.0)).astype(np.int16),
        int(sample_count),
    )


def make_iq_gaussian_sine_interleaved(
    frequency_hz: float,
    phase_rad: float,
    amplitude: float,
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

    ``amplitude`` is normalized to [-1, 1]; 1 is the int16 full scale (32767).
    """

    return _iq_gaussian_sine_codes(
        frequency_hz, phase_rad, _amplitude_to_codes(amplitude), sample_rate_hz, duration_s,
        sample_count=sample_count, fwhm_s=fwhm_s, q_sign=q_sign, hls_xy_drag=hls_xy_drag,
        drag_alpha=drag_alpha, drag_delta_hz=drag_delta_hz,
    )


def _iq_gaussian_sine_codes(
    frequency_hz: float,
    phase_rad: float,
    amplitude_codes: float,
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
    """``make_iq_gaussian_sine_interleaved`` with the amplitude given in int16 DAC codes.

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
    wave = (envelope + 1j * quadrature) * np.exp(1j * int(q_sign) * angle) * float(amplitude_codes)
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
    *,
    copy: bool = True,
) -> np.ndarray:
    """Convert ez-Q IQ/real forms into little-endian ``I0,Q0,I1,Q1`` lanes.

    With ``copy=False`` data that is already in wire order (``packed_iq``,
    ``interleaved_iq``) is returned as a view of the caller's array.
    """
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
            return packed.view("<i2").copy() if copy else packed.view("<i2")
        if wave_format in {"interleaved_iq", "interleaved", "iq_interleaved"}:
            interleaved = np.ascontiguousarray(arr, dtype="<i2").reshape(-1)
            if interleaved.size % 2:
                raise WaveformFormatError("interleaved_iq wave must contain an even number of int16 lanes")
            return interleaved.copy() if copy else interleaved
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


_LANE_SAMPLES = DDR_INTERLEAVED_LANE_BYTES // 2      # int16 values of one channel in one DDR word


class LaneImage:
    """The 512-bit DDR image of up to eight channel streams, not yet built.

    One 64-byte DDR word holds an 8-byte lane per channel, CH1 first; a lane
    is four little-endian int16 values of that channel.  ``len()`` is the
    image size in bytes and :meth:`pack` builds any part of it.  The bulk
    sender gathers the lanes from the channel arrays while it sends, so a
    multi-gigabyte upload never holds a second copy of the data.

    ``samples`` pads the image to at least that many int16 values per channel
    (a channel that is masked off still decides the length).
    """

    def __init__(self, channel_waves: Mapping[int, np.ndarray | list], *, samples: int = 0) -> None:
        self.lanes: list[np.ndarray | None] = [None] * DDR_INTERLEAVED_CHANNELS
        longest = int(samples)
        for channel, wave in channel_waves.items():
            if wave is None:
                continue
            if not 1 <= int(channel) <= DDR_INTERLEAVED_CHANNELS:
                raise ParameterRangeError("channel must be in 1..8")
            lane = np.ascontiguousarray(wave, dtype="<i2").reshape(-1)
            self.lanes[int(channel) - 1] = lane
            longest = max(longest, int(lane.size))
        self.samples = align_bytes_to_beat(longest * 2) // 2
        self.nbytes = self.samples // _LANE_SAMPLES * DDR_INTERLEAVED_BEAT_BYTES

    def __len__(self) -> int:
        return self.nbytes

    def pack(self, start: int = 0, end: int | None = None) -> np.ndarray:
        """Bytes ``start:end`` of the image as a flat ``uint8`` array."""
        end = self.nbytes if end is None else int(end)
        start = int(start)
        if not 0 <= start <= end <= self.nbytes:
            raise ParameterRangeError("range must lie inside the image")
        first = start // DDR_INTERLEAVED_BEAT_BYTES
        last = -(-end // DDR_INTERLEAVED_BEAT_BYTES)
        # words x channels x samples-per-lane, in memory exactly the DDR byte order
        words = np.zeros((last - first, DDR_INTERLEAVED_CHANNELS, _LANE_SAMPLES), dtype="<i2")
        for index, lane in enumerate(self.lanes):
            if lane is None:
                continue
            begin = first * _LANE_SAMPLES
            count = min(last * _LANE_SAMPLES, int(lane.size)) - begin
            if count <= 0:
                continue
            whole = count // _LANE_SAMPLES
            words[:whole, index, :] = lane[begin:begin + whole * _LANE_SAMPLES].reshape(whole, _LANE_SAMPLES)
            if count % _LANE_SAMPLES:
                words[whole, index, :count % _LANE_SAMPLES] = lane[begin + whole * _LANE_SAMPLES:begin + count]
        offset = first * DDR_INTERLEAVED_BEAT_BYTES
        return words.reshape(-1).view(np.uint8)[start - offset:end - offset]


def pack_interleaved_512b_image(channel_waves: Mapping[int, np.ndarray | list]) -> tuple[np.ndarray, int]:
    """Pack eight channel-local streams into 512-bit ``CH1..CH8`` lanes.

    Returns the image as a flat ``uint8`` array and the padded sample count
    per channel.
    """
    if not channel_waves:
        return np.zeros(0, dtype=np.uint8), 0
    lanes = LaneImage(channel_waves)
    return lanes.pack(), lanes.samples


def pack_interleaved_512b_waveforms(channel_waves: Mapping[int, np.ndarray | list]) -> tuple[bytes, int]:
    """:func:`pack_interleaved_512b_image` with the image as ``bytes``."""
    image, samples = pack_interleaved_512b_image(channel_waves)
    return image.tobytes(), samples


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
