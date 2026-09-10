"""正式板级示例入口的静态契约测试。

这些测试不连接真实硬件，只防止示例脚本重新退化成一堆相互矛盾的旧入口，
并锁定用户要求的调用顺序。
"""

from __future__ import annotations

import ast
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "software/dr47/examples"
COMMON = EXAMPLES / "_common.py"

FORMAL = {
    "hardware_slave_wait_sync_trigger_test.py",
    "hardware_master_slave_sync_trigger_test.py",
    "hardware_slave_bypass_trigger_test.py",
    "hardware_slave_bypass_sweep_trigger_test.py",
}

# Bench diagnostics, deliberately kept out of FORMAL: they target one specific
# measurement setup rather than a supported operating mode, so they are allowed
# to exist but must be listed here explicitly.  That keeps the "no silent
# regrowth of contradictory entrypoints" guarantee intact.
BENCH = {
    "hardware_slave_xs18_loopback_trigger_test.py",
    "hardware_external_tdc_trigger_test.py",
    "hardware_slave_phase_compensation_test.py",
}

OLD_DUPLICATES = {
    "hardware_dual_slave_external_trigger_test.py",
    "hardware_master_slave_continuous_trigger_test.py",
    "hardware_master_slave_deterministic_sync_test.py",
    "hardware_master_slave_gaussian_sine_test.py",
    "hardware_master_slave_one_sync_many_trigger_test.py",
    "hardware_master_slave_single_trigger_test.py",
    "hardware_master_slave_wave_test.py",
    "hardware_master_standalone_wave_test.py",
    "hardware_slave_bypass_software_trigger_test.py",
    "hardware_slave_external_trigger_test.py",
}


def _called_methods(tree: ast.AST) -> set[str]:
    return {
        node.func.attr
        for node in ast.walk(tree)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
    }


class ExampleScriptTests(unittest.TestCase):
    def test_only_supported_formal_entrypoints_remain(self):
        actual = {
            path.name
            for path in EXAMPLES.glob("*.py")
            if path.name != "__init__.py" and not path.name.startswith("_")
        }
        self.assertEqual(actual, FORMAL | BENCH)
        self.assertFalse(OLD_DUPLICATES & actual)

    def test_slave_external_waits_sync_then_uploads_and_never_triggers(self):
        path = EXAMPLES / "hardware_slave_wait_sync_trigger_test.py"
        text = path.read_text(encoding="utf-8")
        tree = ast.parse(text)
        called = _called_methods(tree)

        self.assertIn('EXPECTED_SYNC_ROLE = "slave"', text)
        self.assertIn("device.require_external_sync()", text)
        self.assertIn("caps.sync_alignment_epoch != before_epoch", text)
        self.assertIn("while True:", text)
        self.assertIn("loop=False", COMMON.read_text(encoding="utf-8"))
        self.assertIn("common.configure_and_arm", text)
        self.assertIn("common.cleanup", text)
        self.assertIn("_wait_external_triggers", text)
        self.assertNotIn("SYNC_TIMEOUT_S", text)
        self.assertNotIn("等待 SYNC:", text)
        self.assertNotIn("caps.sync_event_epoch", text)
        self.assertNotIn("bypass_sync", called)
        self.assertNotIn("sync", called)
        self.assertNotIn("trigger", called)
        self.assertNotIn("emit_trigger", called)

    def test_master_slave_sync_uploads_only_after_sync_and_triggers_master(self):
        path = EXAMPLES / "hardware_master_slave_sync_trigger_test.py"
        text = path.read_text(encoding="utf-8")
        tree = ast.parse(text)
        called = _called_methods(tree)

        self.assertIn("common.enroll", text)
        self.assertIn("SyncGroup", text)
        self.assertIn("group = SyncGroup", text)
        self.assertIn("group.sync(", text)
        self.assertIn("TRIGGER_COUNT = 20", text)
        self.assertIn("loop=False", COMMON.read_text(encoding="utf-8"))
        self.assertIn("master.trigger()", text)
        self.assertNotIn("slave.trigger()", text)
        self.assertNotIn("master.emit_trigger()", text)
        sync_pos = text.index("group.sync(")
        upload_pos = text.index("common.configure_and_arm")
        self.assertLess(sync_pos, upload_pos)
        self.assertIn("_wait_prepared", text)
        self.assertIn("trigger_accepted_count", text)
        self.assertIn("cleanup", text)

    def test_slave_bypass_has_two_explicit_trigger_modes(self):
        path = EXAMPLES / "hardware_slave_bypass_trigger_test.py"
        text = path.read_text(encoding="utf-8")
        tree = ast.parse(text)
        called = _called_methods(tree)

        self.assertIn('TEST_MODE = "bypass_software_trigger"', text)
        self.assertIn('"bypass_software_trigger"', text)
        self.assertIn('"bypass_external_trigger"', text)
        self.assertIn("device.bypass_sync()", text)
        self.assertIn("device.trigger()", text)
        self.assertIn("loop=False", COMMON.read_text(encoding="utf-8"))
        self.assertIn("while True:", text)
        self.assertNotIn("device.sync()", text)

    def test_slave_bypass_sweep_groups_external_triggers_and_retunes(self):
        path = EXAMPLES / "hardware_slave_bypass_sweep_trigger_test.py"
        text = path.read_text(encoding="utf-8")
        ast.parse(text)

        self.assertIn('EXPECTED_SYNC_ROLE = "slave"', text)
        self.assertIn("SWEEP_ENABLED = True", text)
        self.assertIn("START_FREQUENCY_GHZ = 4.000", text)
        self.assertIn("FREQUENCY_STEP_GHZ = 0.001", text)
        config = ast.parse(text)
        trigger_assignments = [
            node
            for node in config.body
            if isinstance(node, ast.Assign)
            and any(
                isinstance(target, ast.Name)
                and target.id == "TRIGGERS_PER_FREQUENCY"
                for target in node.targets
            )
        ]
        self.assertEqual(len(trigger_assignments), 1)
        trigger_value = ast.literal_eval(trigger_assignments[0].value)
        self.assertIsInstance(trigger_value, int)
        self.assertGreater(trigger_value, 0)
        self.assertIn("device.bypass_sync()", text)
        self.assertIn("device.abort_mute()", text)
        self.assertIn("set_xy_target_frequency", COMMON.read_text(encoding="utf-8"))
        self.assertIn("common.configure_and_arm", text)
        self.assertIn("channels=(1, 2)", text)
        self.assertIn("trigger_input_count", text)
        self.assertIn("trigger_accepted_count", text)
        self.assertIn("common.wait_state", text)
        self.assertNotIn("device.require_external_sync()", text)
        self.assertNotIn("device.sync()", text)
        self.assertNotIn("device.trigger()", text)
        self.assertNotIn("device.emit_trigger()", text)
        self.assertIn("cleanup", text)

    def test_slave_external_trigger_diagnostic_arms_ch1_and_ch2(self):
        path = EXAMPLES / "hardware_slave_xs18_loopback_trigger_test.py"
        text = path.read_text(encoding="utf-8")
        tree = ast.parse(text)
        called = _called_methods(tree)

        self.assertIn("CH1/CH2", text)
        self.assertIn("channels=(1, 2)", text)
        self.assertIn("BURST_DELAY_NS", text)
        self.assertIn("BURST_INTERVAL_NS", text)
        self.assertIn("BURST_COUNT", text)
        self.assertIn("make_gaussian_burst_record", text)
        self.assertIn("bulk_upload=True", text)
        self.assertIn("XS19 Trigger 输入/接受=", text)
        self.assertIn("device.bypass_sync()", text)
        self.assertIn("_wait_external_triggers", text)
        self.assertIn("common.configure_and_arm", text)
        self.assertIn("loop=False", text)
        self.assertNotIn("device.trigger()", text)
        self.assertNotIn("device.emit_trigger()", text)
        self.assertNotIn("trigger", called)
        self.assertNotIn("emit_trigger", called)


if __name__ == "__main__":
    unittest.main()
