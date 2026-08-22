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

    def test_executor_watermarks_fit_reduced_fifo(self):
        top = (REPO_ROOT / "hardware" / "vivado" / "src" / "Top.v").read_text(
            encoding="utf-8", errors="ignore"
        )

        self.assertIn(".LOW_WM(256)", top)
        self.assertIn(".START_WM(512)", top)
        self.assertIn(".HIGH_WM(768)", top)


if __name__ == "__main__":
    unittest.main()
