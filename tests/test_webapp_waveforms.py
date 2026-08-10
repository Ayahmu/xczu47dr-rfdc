import sys
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SOFTWARE_DIR = ROOT / "software"
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(SOFTWARE_DIR))

from software.webapp.models import WaveformRequest  # noqa: E402
from software.webapp.waveforms import to_waveform_config  # noqa: E402
import waveform_model  # noqa: E402


def manual_request(loop: bool, delay_ns: float = 0.0, duration_ns: float = 500.0) -> WaveformRequest:
    return WaveformRequest(
        name="manual waveform config",
        mode="manual",
        loop=loop,
        record_duration_ns=10_000.0 if loop else 1000.0,
        manual_channels=[
            {
                "channel": channel,
                "enabled": channel == 1,
                "waveform": "xy" if channel <= 4 else "z" if channel <= 6 else "readout",
                "format": "real" if channel in (5, 6) else "iq",
                "frequency_mhz": 20.0,
                "data_offset_mhz": 20.0,
                "phase_deg": 0.0,
                "amplitude": 12000,
                "data_amplitude": 0.4,
                "duration_ns": duration_ns,
                "delay_ns": delay_ns,
                "target_rf_mhz": 4500.0,
                "nco_mhz": -1900.0,
                "nyquist_zone": 2,
                "nco_phase_deg": 0.0,
            }
            for channel in range(1, 9)
        ],
    )


class WebappWaveformTests(unittest.TestCase):
    def test_loop_config_uses_shared_record_and_per_channel_duration(self):
        config = to_waveform_config(manual_request(loop=True))

        self.assertTrue(config.loop)
        self.assertAlmostEqual(config.record_duration_s, 10_000e-9)
        self.assertAlmostEqual(config.ch1.duration_s, 500e-9)
        self.assertEqual(config.ch1.zero_tail_s, 0.0)
        self.assertEqual(config.ch1.domain, "iq")
        self.assertTrue(config.wait_for_trigger)

    def test_single_config_uses_shared_record_without_legacy_zero_tail(self):
        config = to_waveform_config(manual_request(loop=False))

        self.assertFalse(config.loop)
        self.assertAlmostEqual(config.record_duration_s, 1000e-9)
        self.assertAlmostEqual(config.ch1.duration_s, 500e-9)
        self.assertEqual(config.ch1.zero_tail_s, 0.0)

    def test_delay_is_padded_with_zeros_inside_shared_record(self):
        request = manual_request(loop=True, delay_ns=100.0, duration_ns=500.0)
        request.record_duration_ns = 1000.0
        config = to_waveform_config(request)
        generated = waveform_model.generate_waveforms(config)
        wave = generated.ch1
        sample_rate = config.sample_rate_hz
        delay_complex = int(round(100e-9 * sample_rate))
        duration_complex = int(round(500e-9 * sample_rate))

        self.assertFalse(np.any(wave[: delay_complex * 2]))
        self.assertTrue(np.any(wave[delay_complex * 2 : (delay_complex + duration_complex) * 2]))
        self.assertFalse(np.any(wave[(delay_complex + duration_complex) * 2 :]))

    def test_delay_plus_duration_must_fit_record(self):
        request = manual_request(loop=True, delay_ns=600.0, duration_ns=500.0)
        request.record_duration_ns = 1000.0

        with self.assertRaisesRegex(ValueError, "exceeds record/loop cache length"):
            to_waveform_config(request)


if __name__ == "__main__":
    unittest.main()
