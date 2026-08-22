import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = REPO_ROOT / "hardware" / "vivado" / "scripts"
MAKEFILE = REPO_ROOT / "Makefile"


class VivadoBuildOptionsTests(unittest.TestCase):
    def test_ila_depth_is_low_and_overridable(self):
        for script_name in ("ila_dac_axis.tcl", "ila_s_axi_01.tcl", "ila_udp_ddr.tcl"):
            script = (SCRIPTS / script_name).read_text(encoding="utf-8", errors="ignore")
            self.assertIn("build_option_get ILA_DEPTH 1024", script)
            self.assertIn("CONFIG.C_DATA_DEPTH ${ila_data_depth}", script)
            self.assertNotIn("CONFIG.C_DATA_DEPTH {4096}", script)

    def test_impl_reuses_completed_ooc_runs(self):
        script = (SCRIPTS / "run_impl.tcl").read_text(encoding="utf-8", errors="ignore")
        self.assertIn("skipping duplicate synthesis", script)
        self.assertIn("ooc_run_complete ${rfdc_run}", script)
        self.assertIn("ooc_run_complete ${ddr_run}", script)

    def test_impl_supports_fast_balanced_and_aggressive_profiles(self):
        script = (SCRIPTS / "run_impl.tcl").read_text(encoding="utf-8", errors="ignore")
        self.assertIn("build_option_get IMPL_MODE auto", script)
        self.assertIn("set impl_profiles [list balanced aggressive]", script)
        self.assertIn("set place_directive Quick", script)
        self.assertIn("ExtraNetDelay_high", script)
        self.assertIn("AggressiveExplore", script)
        self.assertIn('string match "*Complete*"', script)

    def test_makefile_exposes_project_reuse_build(self):
        makefile = MAKEFILE.read_text(encoding="utf-8", errors="ignore")
        self.assertIn("hardware-fast:", makefile)
        self.assertIn("TARGET=$(TARGET) ./build.sh", makefile)
        self.assertIn("TARGET=$(TARGET) ./build.sh --clean", makefile)


if __name__ == "__main__":
    unittest.main()
