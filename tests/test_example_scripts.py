"""驱动板级示例脚本的静态契约测试。"""

from pathlib import Path
import ast
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ExampleScriptTests(unittest.TestCase):
  def test_dual_slave_external_trigger_example_has_external_only_flow(self):
    """双从卡示例必须等待真实 SYNC/Trigger，不能偷偷 bypass 或本地触发。"""

    path = ROOT / "software/dr47/examples/hardware_dual_slave_external_trigger_test.py"
    text = path.read_text(encoding="utf-8")

    self.assertIn('sync_role="slave"', text)
    self.assertEqual(text.count("BoardNetworkAssignment("), 2)
    self.assertIn("device.require_external_sync()", text)
    tree = ast.parse(text)
    called_methods = {
        node.func.attr
        for node in ast.walk(tree)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
    }
    self.assertNotIn("bypass_sync", called_methods)
    self.assertNotIn("sync", called_methods)
    self.assertNotIn("trigger", called_methods)
    self.assertNotIn("emit_trigger", called_methods)
    self.assertIn("_wait_external_sync", text)
    self.assertIn("_configure_upload_and_arm", text)
    self.assertIn("_wait_external_triggers", text)
