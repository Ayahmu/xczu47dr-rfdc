"""唯一板级测试入口的静态契约测试。"""

from __future__ import annotations

import ast
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "software/dr47/examples"
SCRIPT_NAME = "hardware_slave_bypass_external_trigger_test.py"


def called_methods(tree: ast.AST) -> set[str]:
    return {
        node.func.attr
        for node in ast.walk(tree)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
    }


class ExampleScriptTests(unittest.TestCase):
    def test_only_one_hardware_test_remains(self):
        scripts = {
            path.name
            for path in EXAMPLES.glob("hardware_*_test.py")
        }
        self.assertEqual(scripts, {SCRIPT_NAME})

    def test_configuration_is_defined_in_source(self):
        text = (EXAMPLES / SCRIPT_NAME).read_text(encoding="utf-8")
        tree = ast.parse(text)

        self.assertIn('BOARD_IP = "169.254.149.60"', text)
        self.assertIn('UDP_INTERFACE = "enp1s0f0"', text)
        self.assertIn('UDP_SOURCE_IP = "169.254.250.11"', text)
        self.assertNotIn("os.environ", text)
        self.assertNotIn("os.getenv", text)
        self.assertNotIn("argparse", text)
        self.assertNotIn("sys.argv", text)
        self.assertFalse(
            any(
                isinstance(node, ast.ImportFrom) and node.module == "argparse"
                for node in ast.walk(tree)
            )
        )

    def test_bypasses_sync_and_only_waits_for_external_trigger(self):
        text = (EXAMPLES / SCRIPT_NAME).read_text(encoding="utf-8")
        tree = ast.parse(text)
        methods = called_methods(tree)

        self.assertIn("bypass_sync", methods)
        self.assertIn("configure_playback", methods)
        self.assertIn("arm_playback", methods)
        self.assertIn("abort_playback", methods)
        self.assertIn("trigger_input_count", text)
        self.assertIn("trigger_accepted_count", text)
        self.assertNotIn("trigger", methods)
        self.assertNotIn("trigger_playback", methods)
        self.assertNotIn("emit_trigger", methods)
        self.assertNotIn("sync", methods)


if __name__ == "__main__":
    unittest.main()
