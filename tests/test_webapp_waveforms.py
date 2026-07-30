import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOFTWARE_DIR = ROOT / "software"
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(SOFTWARE_DIR))

from software.webapp.models import WaveformRequest  # noqa: E402
from software.webapp.waveforms import to_waveform_config  # noqa: E402


def manual_request(loop: bool) -> WaveformRequest:
    return WaveformRequest(
        name="manual loop tail check",
        mode="manual",
        loop=loop,
        record_duration_ns=10_000.0 if loop else 1000.0,
        manual_channels=[
            {
                "channel": channel,
                "enabled": channel == 1,
                "waveform": "iq-sine",
                "frequency_mhz": 20.0,
                "phase_deg": 0.0,
                "amplitude": 12000,
                "duration_ns": 1000.0,
            }
            for channel in range(1, 9)
        ],
    )


class WebappWaveformTests(unittest.TestCase):
    def test_loop_manual_sine_omits_zero_tail(self):
        config = to_waveform_config(manual_request(loop=True))

        self.assertTrue(config.loop)
        self.assertEqual(config.ch1.zero_tail_s, 0.0)
        self.assertEqual(config.ch2.zero_tail_s, 0.0)
        self.assertAlmostEqual(config.ch1.duration_s, 10_000e-9)
        self.assertTrue(config.wait_for_trigger)

    def test_single_manual_sine_keeps_zero_tail(self):
        config = to_waveform_config(manual_request(loop=False))

        self.assertFalse(config.loop)
        self.assertEqual(config.ch1.zero_tail_s, 50e-9)
        self.assertAlmostEqual(config.ch1.duration_s, 1000e-9)

    def test_loop_manual_sine_rejects_nonperiodic_record(self):
        request = manual_request(loop=True).model_copy(deep=True)
        request.manual_channels[0].frequency_mhz = 20.55

        with self.assertRaisesRegex(ValueError, "not periodic"):
            to_waveform_config(request)


if __name__ == "__main__":
    unittest.main()
