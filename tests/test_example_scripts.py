"""唯一板级测试入口的静态契约测试。"""

from __future__ import annotations

import ast
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "software/dr47/examples"
SCRIPT_NAME = "waveform_external_trigger_example.py"


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
            for path in EXAMPLES.glob("waveform_*_example.py")
        }
        self.assertEqual(scripts, {"waveform_external_trigger_example.py", "waveform_software_play_example.py"})

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

    def test_uses_single_board_waveform_protocol_and_external_trigger(self):
        text = (EXAMPLES / SCRIPT_NAME).read_text(encoding="utf-8")
        tree = ast.parse(text)
        methods = called_methods(tree)

        self.assertIn("upload_waveforms", methods)
        self.assertIn("waveform_status", methods)
        self.assertIn("stop", methods)
        self.assertIn("WAVECTR0", text)
        self.assertIn("external XS19 Trigger", text)
        self.assertNotIn("bypass_sync", text)
        self.assertNotIn("sync_role", text)
        self.assertNotIn("arm_playback", text)
        self.assertNotIn("abort_playback", text)
        self.assertNotIn("trigger", methods)
        self.assertNotIn("trigger_playback", methods)
        self.assertNotIn("emit_trigger", methods)
        self.assertNotIn("sync", methods)


if __name__ == "__main__":
    unittest.main()
