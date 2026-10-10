"""Build identity must describe the netlist that was actually synthesized.

The checks run the real build_identity.tcl procs under tclsh with the few
Vivado commands they use stubbed, so no Vivado licence or project is needed.
"""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
IDENTITY = REPO_ROOT / "hardware" / "vivado" / "scripts" / "build_identity.tcl"

STUBS = """
proc get_runs {args} { return synth_1 }
proc get_property {name obj} { return $::run_dir }
"""


@unittest.skipUnless(shutil.which("tclsh"), "tclsh is unavailable")
class BuildIdentityTests(unittest.TestCase):
    def run_check(self, manifest_commit: str, compiled_commit: str) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            manifest = tmp_path / "build_manifest.json"
            manifest.write_text(
                '{"target":"custom_xczu47dr_waveform","protocol_version":3,"build_profile_id":1,'
                f'"trigger_path_version":3,"source_commit":"{manifest_commit}","source_dirty":0}}'
            )
            (tmp_path / "TopCustomXczu47dr.tcl").write_text(
                "set_property verilog_define {CUSTOM_XCZU47DR RF2_BUILD_PROFILE_ID=32'd1 "
                f"RF2_TRIGGER_PATH_VERSION=32'd3 RF2_SOURCE_COMMIT_ID=32'h{compiled_commit}}} "
                "[current_fileset]\n"
            )
            script = tmp_path / "check.tcl"
            script.write_text(
                f"set ::run_dir {{{tmp_path}}}\n{STUBS}\nsource {{{IDENTITY}}}\n"
                f"rf2_identity_validate_synth_run {{{manifest}}} synth_1 TopCustomXczu47dr\n"
            )
            return subprocess.run(["tclsh", str(script)], capture_output=True, text=True, timeout=30)

    def test_matching_synth_run_passes(self):
        result = self.run_check("01f7681a", "01f7681a")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("matches the build manifest", result.stdout)

    def test_stale_synth_run_is_rejected(self):
        # The defect seen on hardware: netlist compiled at a78a3ddc while the
        # manifest (and XSA) claimed 01f7681a.
        result = self.run_check("01f7681a", "a78a3ddc")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs from build manifest", result.stderr)

    def test_manifest_records_dirty_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest = Path(tmp) / "m.json"
            script = Path(tmp) / "w.tcl"
            script.write_text(
                f"source {{{IDENTITY}}}\n"
                f"rf2_identity_write_manifest {{{manifest}}} custom_xczu47dr_waveform 01f7681a 1 3 1\n"
            )
            result = subprocess.run(["tclsh", str(script)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('"source_dirty":1', manifest.read_text())
            self.assertIn("uncommitted changes", result.stdout)


if __name__ == "__main__":
    unittest.main()
