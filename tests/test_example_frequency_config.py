"""唯一板级测试脚本的频率和波形配置测试。"""

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


class ExampleFrequencyConfigTests(unittest.TestCase):
    def test_example_uses_explicit_amplitude_and_gain(self):
        self.assertEqual(example.GAUSSIAN_AMPLITUDE, 0.10)
        self.assertEqual(example.OUTPUT_GAIN, 0.10)

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
