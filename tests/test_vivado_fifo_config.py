import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
FIFO_TCL = REPO_ROOT / "hardware" / "vivado" / "scripts" / "axis_async_fifo_256.tcl"


class VivadoFifoConfigTests(unittest.TestCase):
    def test_playback_fifo_keeps_async_bram_with_reduced_depth(self):
        script = FIFO_TCL.read_text(encoding="utf-8", errors="ignore")

        self.assertIn("CONFIG.FIFO_DEPTH {1024}", script)
        self.assertIn("CONFIG.FIFO_MEMORY_TYPE {block}", script)
        self.assertIn("CONFIG.IS_ACLK_ASYNC {1}", script)
        self.assertIn("CONFIG.PROG_EMPTY_THRESH {64}", script)
        self.assertIn("CONFIG.PROG_FULL_THRESH {768}", script)
        self.assertNotIn("CONFIG.FIFO_MEMORY_TYPE {ultra}", script)

    def test_waveform_path_start_watermark_and_loop_contract_are_explicit(self):
        path = (REPO_ROOT / "hardware" / "vivado" / "src" / "waveform_playback_path.v").read_text(
            encoding="utf-8", errors="ignore"
        )
        controller = (REPO_ROOT / "hardware" / "vivado" / "src" / "waveform_playback_controller.v").read_text(
            encoding="utf-8", errors="ignore"
        )

        self.assertIn("parameter integer START_WATERMARK = 768", path)
        self.assertIn("FIFO_RESET_GUARD_CYCLES = 16", path)
        self.assertIn("loop_count", controller)
        self.assertIn("loop_restart", controller)


if __name__ == "__main__":
    unittest.main()
