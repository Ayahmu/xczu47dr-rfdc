import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
HMC7044_VHDL = REPO_ROOT / "hardware" / "vivado" / "src" / "hmc7044.vhd"
VCXO_HZ = 100_000_000.0


def _hmc7044_registers() -> dict[int, int]:
    text = HMC7044_VHDL.read_text(encoding="utf-8", errors="ignore")
    matches = re.findall(r'config_reg\s*<=\s*x"([0-9A-Fa-f]{4})"\s*&\s*x"([0-9A-Fa-f]{2})"', text)
    return {int(addr, 16): int(value, 16) for addr, value in matches}


def _reg12(registers: dict[int, int], low_addr: int, high_addr: int) -> int:
    return registers[low_addr] | ((registers[high_addr] & 0x0F) << 8)


class Hmc7044ConfigTests(unittest.TestCase):
    def test_dac_refclk_registers_generate_exact_128_mhz_with_supported_divider(self):
        regs = _hmc7044_registers()
        pll2_r2 = _reg12(regs, 0x0033, 0x0034)
        pll2_n2 = _reg12(regs, 0x0035, 0x0036)
        vco_hz = VCXO_HZ / pll2_r2 * pll2_n2

        self.assertEqual(pll2_r2, 25)
        self.assertEqual(pll2_n2, 768)
        self.assertEqual(vco_hz, 3_072_000_000.0)

        for low_addr, high_addr in ((0x00F1, 0x00F2), (0x0105, 0x0106)):
            divider = _reg12(regs, low_addr, high_addr)
            self.assertEqual(divider, 24)
            self.assertEqual(vco_hz / divider, 128_000_000.0)

    def test_dac_refclk_avoids_unsupported_odd_divide_25(self):
        regs = _hmc7044_registers()
        self.assertNotEqual(_reg12(regs, 0x00F1, 0x00F2), 25)
        self.assertNotEqual(_reg12(regs, 0x0105, 0x0106), 25)

    def test_sysref_is_integer_submultiple_of_dac_refclk(self):
        regs = _hmc7044_registers()
        pll2_r2 = _reg12(regs, 0x0033, 0x0034)
        pll2_n2 = _reg12(regs, 0x0035, 0x0036)
        vco_hz = VCXO_HZ / pll2_r2 * pll2_n2

        for low_addr, high_addr in ((0x00FB, 0x00FC), (0x010F, 0x0110)):
            divider = _reg12(regs, low_addr, high_addr)
            self.assertEqual(divider, 1536)
            self.assertEqual(vco_hz / divider, 2_000_000.0)


if __name__ == "__main__":
    unittest.main()
