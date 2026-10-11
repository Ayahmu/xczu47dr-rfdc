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
    def test_board_test_scripts_are_exactly_the_documented_set(self):
        scripts = {
            path.name
            for path in EXAMPLES.glob("waveform_*_example.py")
        }
        self.assertEqual(scripts, {
            "waveform_external_trigger_example.py",
            "waveform_software_play_example.py",
            "waveform_bulk_upload_speed_example.py",
            "waveform_100g_stress_example.py",
        })
        # Every script in the directory is listed in the driver README.
        readme = (ROOT / "software/dr47/README.md").read_text(encoding="utf-8")
        for path in EXAMPLES.glob("*.py"):
            if path.name != "__init__.py":
                self.assertIn(path.name, readme)

    def test_speed_test_measures_the_bulk_path_through_the_public_call(self):
        text = (EXAMPLES / "waveform_bulk_upload_speed_example.py").read_text(encoding="utf-8")
        methods = called_methods(ast.parse(text))
        self.assertIn("upload_waveforms", methods)
        self.assertIn("play", methods)
        self.assertIn("waveform_status", methods)
        for reported in ('result["transport"]', "resent_chunks", "underflow_count", "Gb/s"):
            self.assertIn(reported, text)
        for forbidden in ("argparse", "sys.argv", "os.environ", "os.getenv"):
            self.assertNotIn(forbidden, text)

    def test_stress_test_reports_bandwidth_and_loss_per_stage(self):
        text = (EXAMPLES / "waveform_100g_stress_example.py").read_text(encoding="utf-8")
        methods = called_methods(ast.parse(text))
        # Raw single-send loss: the session is opened and read back, but never
        # resent, committed or played.
        for used in ("begin_waveform", "bulk_status", "send", "abort"):
            self.assertIn(used, methods)
        for unused in ("bulk_chunk_reset", "commit_waveform", "upload_waveforms", "play"):
            self.assertNotIn(unused, methods)
        for reported in ("goodput", "wire", "board_rx", "bad_fcs", "fifo_full", "rejected", "stored", "loss",
                         "MAX_LOSS_RATE", "Gb/s"):
            self.assertIn(reported, text)
        for forbidden in ("argparse", "sys.argv", "os.environ", "os.getenv"):
            self.assertNotIn(forbidden, text)

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
