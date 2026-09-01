"""250 MHz 板级示例的目标 RF 频率与默认满幅配置测试。"""

import unittest

from software.dr47 import rfdc_nco_plan_for_target
from software.dr47.examples import _common as common


class ExampleFrequencyConfigTests(unittest.TestCase):
    def test_common_examples_use_full_amplitude_and_gain_by_default(self):
        self.assertEqual(common.AMPLITUDE, 1.0)
        self.assertEqual(common.GAIN, 1.0)

    def test_common_target_frequency_uses_second_nyquist_zone_above_3_2ghz(self):
        plan = rfdc_nco_plan_for_target(4.0, dac_fs_ghz=6.4)
        self.assertEqual(plan["target_rf_ghz"], 4.0)
        self.assertEqual(plan["nco_ghz"], -2.4)
        self.assertEqual(plan["nyquist_zone"], 2)

    def test_common_configurator_applies_target_frequency_plan(self):
        source = common.configure_and_arm.__code__.co_names
        self.assertIn("set_xy_target_frequency", source)


if __name__ == "__main__":
    unittest.main()
