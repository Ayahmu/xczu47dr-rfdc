"""唯一板级测试脚本的频率和波形配置测试。"""

import inspect
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SOFTWARE_DIR = REPO_ROOT / "software"

# Examples are written against the flat ``dr47`` package layout that the board
# scripts use (``python <example>.py`` with ``software/`` on the path), so the
# directory has to be importable before the example module is loaded.
if str(SOFTWARE_DIR) not in sys.path:
    sys.path.insert(0, str(SOFTWARE_DIR))

from software.dr47 import rfdc_nco_plan_for_target
from software.dr47.examples import waveform_external_trigger_example as example
from software.dr47.examples import waveform_software_play_example as play_example


class ExampleFrequencyConfigTests(unittest.TestCase):
    def test_examples_use_full_scale_amplitude(self):
        # Normalized amplitude: 1.0 is the maximum (int16 full scale).
        self.assertEqual(example.GAUSSIAN_AMPLITUDE, 1.0)
        self.assertEqual(play_example.GAUSSIAN_AMPLITUDE, 1.0)

    def test_examples_have_no_gain_setting(self):
        for module in (example, play_example):
            self.assertFalse(hasattr(module, "OUTPUT_GAIN"))
            self.assertNotIn("set_gain", inspect.getsource(module))

    def test_full_scale_pulse_reaches_the_int16_limit_without_wrapping(self):
        for waveform in (example.make_gaussian_waveform(), play_example.make_waveform()):
            self.assertEqual(waveform.dtype.str, "<i2")
            self.assertEqual(int(waveform.max()), 32767)
            self.assertGreaterEqual(int(waveform.min()), -32767)

    def test_common_target_frequency_uses_second_nyquist_zone_above_3_2ghz(self):
        plan = rfdc_nco_plan_for_target(4.0, dac_fs_ghz=6.4)
        self.assertEqual(plan["target_rf_ghz"], 4.0)
        self.assertEqual(plan["nco_ghz"], -2.4)
        self.assertEqual(plan["nyquist_zone"], 2)

    def test_example_applies_target_frequency_plan(self):
        source = example.run_test.__code__.co_names
        self.assertIn("set_xy_target_frequency", source)

    def test_gaussian_waveform_is_interleaved_iq(self):
        waveform = example.make_gaussian_waveform()
        self.assertEqual(waveform.dtype.str, "<i2")
        self.assertEqual(waveform.size % 2, 0)
        self.assertTrue((waveform[1::2] == 0).all())


if __name__ == "__main__":
    unittest.main()
