"""三个正式板级示例入口的静态契约测试。

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
    def test_only_three_formal_entrypoints_remain(self):
        actual = {
            path.name
            for path in EXAMPLES.glob("*.py")
            if path.name != "__init__.py" and not path.name.startswith("_")
        }
        self.assertEqual(actual, FORMAL)
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
        self.assertNotIn("device.require_external_sync()", text)
        self.assertIn("cleanup", text)


if __name__ == "__main__":
    unittest.main()
