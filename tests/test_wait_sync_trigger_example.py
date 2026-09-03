"""等待外部 SYNC/Trigger 的单板从卡示例契约测试。"""

import ast
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "software/dr47/examples/hardware_slave_wait_sync_trigger_test.py"


class WaitSyncTriggerExampleTests(unittest.TestCase):
    def test_slave_wait_example_uses_external_sync_and_trigger_only(self):
        """脚本必须先等真实 SYNC，再上传/ARM，并且不能自行触发。"""

        text = SCRIPT.read_text(encoding="utf-8")
        tree = ast.parse(text)
        called_methods = {
            node.func.attr
            for node in ast.walk(tree)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
        }

        self.assertIn('EXPECTED_SYNC_ROLE = "slave"', text)
        self.assertIn("device.require_external_sync()", text)
        self.assertIn("_wait_external_sync", text)
        self.assertIn("_prepare_waveform_after_sync", text)
        self.assertIn("_wait_external_triggers", text)
        self.assertIn("device.upload_waveforms", text)
        self.assertIn("device.arm", text)
        self.assertIn("LOOP_WAVEFORM = False", text)
        self.assertNotIn("LOOP_WAVEFORM = True", text)
        self.assertNotIn("caps.sync_event_epoch", text)
        self.assertIn("caps.sync_alignment_epoch != before_epoch", text)
        self.assertNotIn("SYNC_TIMEOUT_S =", text)
        self.assertIn("while True:", text)
        self.assertNotIn('_print_status(device, "等待 SYNC")', text)
        self.assertNotIn("bypass_sync", called_methods)
        self.assertNotIn("sync", called_methods)
        self.assertNotIn("trigger", called_methods)
        self.assertNotIn("emit_trigger", called_methods)
