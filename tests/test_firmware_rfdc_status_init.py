"""XRFdc_GetIPStatus() only ever sets IsEnabled to 1; it never clears it.

A tile status structure that starts out uninitialised therefore reports
whatever was left on the stack for every disabled tile.  All ADC tiles are
disabled in this design, so a stray 1 makes rfdcStartup() try to start an ADC
tile that does not exist, fail, and leave main() before MTS: the board answers
on the network but never becomes RF-ready.  Seen on hardware on 2026-10-10
("XRFdc_StartUp failed for ADC Tile: 1").
"""

import re
import unittest
from pathlib import Path

MAIN_C = Path(__file__).resolve().parents[1] / "firmware" / "src" / "main.c"
SOURCE = MAIN_C.read_text(encoding="utf-8")


class FirmwareRfdcStatusInitTests(unittest.TestCase):
    def test_every_tile_status_structure_starts_zeroed(self):
        declarations = re.findall(r"^\s*XRFdc_IPStatus\s+\w+[^;]*;", SOURCE, re.M)
        self.assertGreaterEqual(len(declarations), 2)
        for declaration in declarations:
            self.assertRegex(declaration, r"=\s*\{\s*0\s*\}\s*;", declaration.strip())


if __name__ == "__main__":
    unittest.main()
