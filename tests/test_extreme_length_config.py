import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ExtremeLengthConfigTests(unittest.TestCase):
    def test_ddr_ip_exposes_8gib_byte_address_space(self):
        config = (ROOT / "hardware/chisel/generated/ddr_custom_xczu47dr_config.tcl").read_text(encoding="utf-8")

        self.assertIn("CONFIG.C0.DDR4_MemoryPart {MT40A1G16RC-062E}", config)
        self.assertIn("CONFIG.C0.DDR4_DataWidth {64}", config)
        self.assertIn("CONFIG.C0.DDR4_AxiDataWidth {512}", config)
        self.assertIn("CONFIG.C0.DDR4_AxiAddressWidth {33}", config)

    def test_firmware_mailbox_is_in_reserved_top_mebibyte(self):
        source = (ROOT / "firmware/src/main.c").read_text(encoding="utf-8")
        match = re.search(r"#define\s+RFDC_CTRL_MAILBOX_OFFSET\s+(0x[0-9A-Fa-f]+)ULL", source)

        self.assertIsNotNone(match)
        self.assertEqual(int(match.group(1), 16), 0x1FFF00000)

    def test_interleaved_executor_uses_64bit_total_byte_counters(self):
        source = (ROOT / "hardware/vivado/src/waveform_interleaved_system_top.v").read_text(encoding="utf-8")

        self.assertRegex(source, r"reg\s+\[63:0\]\s+inter_total_bytes")
        self.assertRegex(source, r"reg\s+\[63:0\]\s+inter_bytes_left")
        self.assertIn("inter_total_bytes <= {29'd0, max_ch_bytes, 3'd0};", source)

    def test_all_external_ddr_ports_use_aligned_8gib_high_aperture(self):
        normal = (ROOT / "hardware/vivado/bd/ddr_axi_smartconnect.tcl").read_text(encoding="utf-8")
        bandwidth = (ROOT / "hardware/vivado/bd/ddr_axi_smartconnect_bandwidth.tcl").read_text(encoding="utf-8")
        design = (ROOT / "hardware/vivado/bd/design_1.tcl").read_text(encoding="utf-8")
        design_bandwidth = (ROOT / "hardware/vivado/bd/design_1_bandwidth.tcl").read_text(encoding="utf-8")

        self.assertEqual(normal.count("-offset 0x004800000000 -range 0x000200000000"), 3)
        self.assertRegex(normal, r"-range 0x000200000000[^\n]+S_AXI_DM")
        self.assertRegex(normal, r"-range 0x000200000000[^\n]+S_AXI_WAVE")
        self.assertEqual(bandwidth.count("-offset 0x004800000000 -range 0x000200000000"), 2)
        self.assertRegex(bandwidth, r"-range 0x000200000000[^\n]+S_AXI_PL")
        self.assertRegex(design, r"-offset 0x004800000000 -range 0x000200000000[^\n]+M_AXI_PS_DDR")
        self.assertRegex(design_bandwidth, r"-offset 0x004800000000 -range 0x000200000000[^\n]+M_AXI_PS_DDR")

    def test_ddr_wrapper_strips_the_high_aperture_base_before_mig(self):
        source = (ROOT / "hardware/chisel/ddr/src/elaborate.scala").read_text(encoding="utf-8")

        self.assertIn("input  [39:0]   s_axi_awaddr", source)
        self.assertIn("s_axi_awaddr - 40'h48_0000_0000", source)


if __name__ == "__main__":
    unittest.main()
