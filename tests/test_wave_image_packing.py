"""Packing channel waveforms into the 512-bit DDR image.

One 64-byte DDR word holds one 8-byte lane per channel, CH1 first; a lane is
four little-endian int16 values (I0, Q0, I1, Q1).  Short channels are padded
with zeros and the whole image is padded to whole DAC beats.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "software"))

from dr47.waveforms import LaneImage, pack_interleaved_512b_image, pack_interleaved_512b_waveforms  # noqa: E402


def _reference(channel_waves, samples):
    """The layout, written out word by word."""
    image = bytearray(samples // 4 * 64)
    for channel, wave in channel_waves.items():
        data = np.zeros(samples, dtype="<i2")
        data[:len(wave)] = wave
        raw = data.tobytes()
        for word in range(samples // 4):
            image[word * 64 + (channel - 1) * 8: word * 64 + channel * 8] = raw[word * 8: word * 8 + 8]
    return bytes(image)


def test_image_layout_is_one_lane_per_channel_in_every_word():
    rng = np.random.default_rng(3)
    waves = {1: rng.integers(-32768, 32767, 1000, dtype=np.int16),
             3: rng.integers(-32768, 32767, 37, dtype=np.int16),
             8: rng.integers(-32768, 32767, 1024, dtype=np.int16)}
    image, samples = pack_interleaved_512b_waveforms(waves)
    assert isinstance(image, bytes)
    assert samples == 1024 and len(image) == samples // 4 * 64
    assert image == _reference(waves, samples)


def test_image_array_is_the_same_bytes_without_the_copy():
    rng = np.random.default_rng(4)
    waves = {2: rng.integers(-32768, 32767, 4096, dtype=np.int16), 5: [1, -2, 3]}
    image, samples = pack_interleaved_512b_image(waves)
    assert image.dtype == np.uint8 and image.ndim == 1
    assert (image.tobytes(), samples) == pack_interleaved_512b_waveforms(waves)
    assert pack_interleaved_512b_waveforms({}) == (b"", 0)
    assert pack_interleaved_512b_image({})[0].size == 0


def test_packing_keeps_up_with_the_bulk_path():
    # A 64 MiB image.  The old per-word Python loop took 1.7 s for this; the
    # bulk path puts it on the wire in 6 ms.
    wave = np.arange(2 * 1024 * 1024 * 2, dtype=np.int16)
    started = time.perf_counter()
    image, _ = pack_interleaved_512b_image({1: wave})
    elapsed = time.perf_counter() - started
    assert image.size == 64 << 20
    assert elapsed < 0.5


def test_lane_image_packs_any_range_without_building_the_rest():
    rng = np.random.default_rng(6)
    waves = {1: rng.integers(-32768, 32767, 4000, dtype=np.int16),
             4: rng.integers(-32768, 32767, 1030, dtype=np.int16),     # ends inside a lane
             7: rng.integers(-32768, 32767, 4096, dtype=np.int16)}
    whole, samples = pack_interleaved_512b_image(waves)
    lanes = LaneImage(waves)
    assert (len(lanes), lanes.samples) == (whole.size, samples)
    assert lanes.pack().tobytes() == whole.tobytes()
    for start, end in [(0, 64), (64, 1024), (16384, 16384 + 4096), (len(lanes) - 128, len(lanes)), (8192, 8192 + 64 * 300)]:
        assert lanes.pack(start, end).tobytes() == whole[start:end].tobytes()


def test_lane_image_can_be_longer_than_its_data():
    # A masked channel still decides the length; its lane is all zeros.
    lanes = LaneImage({2: np.arange(64, dtype=np.int16)}, samples=200)
    assert lanes.samples == 208 and len(lanes) == 208 // 4 * 64      # padded to whole 16-sample DAC beats
    image = lanes.pack()
    assert image[8:16].tobytes() == np.arange(4, dtype="<i2").tobytes()
    assert not image[64 * 16:].any()


def test_conversion_can_borrow_data_that_is_already_in_wire_order():
    from dr47.waveforms import ezq_wave_to_interleaved_int16

    interleaved = np.arange(64, dtype=np.int16)
    packed = np.arange(32, dtype="<i4")
    # The default hands back an independent array, as before.
    assert not np.shares_memory(ezq_wave_to_interleaved_int16(interleaved, "interleaved_iq"), interleaved)
    assert not np.shares_memory(ezq_wave_to_interleaved_int16(packed, "packed_iq"), packed)
    # An upload reads the data once and never changes it, so it may borrow.
    for wave, wave_format in ((interleaved, "interleaved_iq"), (packed, "packed_iq")):
        borrowed = ezq_wave_to_interleaved_int16(wave, wave_format, copy=False)
        assert np.shares_memory(borrowed, wave)
        assert borrowed.tobytes() == ezq_wave_to_interleaved_int16(wave, wave_format).tobytes()
