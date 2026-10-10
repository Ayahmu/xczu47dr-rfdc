"""The firmware boot default for the DAC output current is the fixed maximum.

The driver always requests these same currents (dr47.protocol._FIXED_DAC_OUTPUT_CURRENT_MA,
pinned in test_waveform_public_api.py), so a board that was never configured by the
driver already outputs at full current.
"""

import re
import unittest
from pathlib import Path

MAIN_C = Path(__file__).resolve().parents[1] / "firmware" / "src" / "main.c"
SOURCE = MAIN_C.read_text(encoding="utf-8")


def function_body(name: str) -> str:
    match = re.search(rf"^(?:static )?\w+ {name}\([^)]*\)\s*\{{", SOURCE, re.M)
    assert match, f"{name} not found"
    depth, index = 1, match.end()
    while depth:
        depth += {"{": 1, "}": -1}.get(SOURCE[index], 0)
        index += 1
    return SOURCE[match.end():index]


class FirmwareDacCurrentTests(unittest.TestCase):
    def test_default_currents_are_the_maximum_of_each_coupling(self):
        self.assertRegex(SOURCE, r"#define\s+DAC_OUTPUT_CURRENT_AC_UA\s+40500U?\b")
        self.assertRegex(SOURCE, r"#define\s+DAC_OUTPUT_CURRENT_DC_UA\s+32000U?\b")

    def test_dc_coupled_channels_are_exactly_the_z_role(self):
        rows = re.findall(r'\{(\d+),\s*(\d+),\s*"CH(\d)",\s*"(\w+)"', SOURCE)
        roles = {int(channel): role for _, _, channel, role in rows}
        self.assertEqual(sorted(roles), list(range(1, 9)))
        self.assertEqual({channel for channel, role in roles.items() if role == "Z"}, {5, 6})
        # The helper keys the DC limit off the same role string as the rest of the file.
        self.assertIn('strcmp(Channel->Role, "Z") == 0', function_body("Custom_DAC_Output_Current_uA"))

    def test_boot_configuration_uses_the_helper_not_a_literal_current(self):
        body = function_body("Configure_DAC_Output_Current")
        self.assertIn("Custom_DAC_Output_Current_uA(", body)
        self.assertNotRegex(body, r"Block_Id,\s*\d+\)")

    def test_adjust_takes_microamps_and_accepts_the_full_range(self):
        body = function_body("Adjust_DAC_Power")
        self.assertRegex(SOURCE, r"int Adjust_DAC_Power\(u32 Tile_Id, u32 Block_Id, u32 CurrentUA\)")
        self.assertIn("CurrentUA < 2250U || CurrentUA > 40500U", body)
        self.assertIn("XRFdc_SetDACVOP(&RFdcInst, Tile_Id, Block_Id, CurrentUA)", body)


if __name__ == "__main__":
    unittest.main()
