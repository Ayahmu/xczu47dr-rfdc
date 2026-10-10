"""The driver's IQ helpers take a normalized amplitude in [-1, 1] (1 = int16 full scale)."""

import math
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "software"))

from dr47 import make_iq_gaussian_sine_interleaved, make_iq_sine_interleaved  # noqa: E402
from dr47.errors import ParameterRangeError  # noqa: E402

FS = 400e6


def sine(amplitude):
    return make_iq_sine_interleaved(0.0, 0.0, amplitude, FS, sample_count=16)


def gaussian(amplitude):
    return make_iq_gaussian_sine_interleaved(0.0, 0.0, amplitude, FS, 100e-9, fwhm_s=40e-9)


@pytest.mark.parametrize("amplitude,peak", [(1.0, 32767), (-1.0, -32767), (0.5, round(0.5 * 32767)), (0.0, 0)])
def test_sine_amplitude_is_a_fraction_of_int16_full_scale(amplitude, peak):
    assert int(sine(amplitude)[0]) == peak  # I0 = amplitude * cos(0)


def test_gaussian_peak_scales_with_normalized_amplitude():
    assert int(gaussian(1.0).max()) == 32767
    assert int(gaussian(0.5).max()) == round(0.5 * 32767)
    assert int(gaussian(-1.0).min()) == -32767


@pytest.mark.parametrize("bad", [1.0001, -1.5, 12000, 32767, math.nan, math.inf, -math.inf])
def test_amplitude_outside_unit_range_is_rejected(bad):
    # 12000 / 32767 are the old DAC-code amplitudes: fail loudly instead of clipping to full scale.
    with pytest.raises(ParameterRangeError, match="amplitude"):
        sine(bad)
    with pytest.raises(ParameterRangeError, match="amplitude"):
        gaussian(bad)
