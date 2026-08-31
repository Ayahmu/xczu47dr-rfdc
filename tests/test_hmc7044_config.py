import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
HMC7044_VHDL = REPO_ROOT / "hardware" / "vivado" / "src" / "hmc7044.vhd"
TOP_VERILOG = REPO_ROOT / "hardware" / "vivado" / "src" / "Top.v"
TARGET_CONFIG = REPO_ROOT / "hardware" / "vivado" / "scripts" / "target_config.tcl"
FIRMWARE_MAIN = REPO_ROOT / "firmware" / "src" / "main.c"
FIRMWARE_MAIN_H = REPO_ROOT / "firmware" / "src" / "main.h"
RFCTRL2_RTL = REPO_ROOT / "hardware" / "vivado" / "src" / "pl_riscv_control_v1.v"
HOST_SOFTWARE = REPO_ROOT / "software" / "host.py"
VCXO_HZ = 100_000_000.0


def _hmc7044_registers() -> dict[int, int]:
    text = HMC7044_VHDL.read_text(encoding="utf-8", errors="ignore")
    matches = re.findall(r'config_reg\s*<=\s*x"([0-9A-Fa-f]{4})"\s*&\s*x"([0-9A-Fa-f]{2})"', text)
    return {int(addr, 16): int(value, 16) for addr, value in matches}


def _reg12(registers: dict[int, int], low_addr: int, high_addr: int) -> int:
    return registers[low_addr] | ((registers[high_addr] & 0x0F) << 8)


class Hmc7044ConfigTests(unittest.TestCase):
    def test_targets_use_the_external_250mhz_xs17_profile(self):
        top = TOP_VERILOG.read_text(encoding="utf-8", errors="ignore")
        target_config = TARGET_CONFIG.read_text(encoding="utf-8", errors="ignore")

        self.assertRegex(top, r"hmc_use_external_250mhz\s*=\s*1'b1")
        self.assertIn("clock_policy external_250mhz_xs17", target_config)

    def test_firmware_clock_constants_match_250mhz_profile(self):
        text = FIRMWARE_MAIN_H.read_text(encoding="utf-8", errors="ignore")
        self.assertRegex(text, r"#define HMC7044_INPUT_REF_HZ\s+250000000U")
        self.assertRegex(text, r"#define HMC7044_PLL1_PFD_HZ\s+10000000U")
        self.assertRegex(text, r"#define HMC7044_DAC_REFCLK_HZ\s+128000000U")

    def test_firmware_psu_init_paths_match_vitis_output_layout(self):
        text = TARGET_CONFIG.read_text(encoding="utf-8", errors="ignore")
        self.assertIn("custom_xczu47dr_master/hw_platform/hw/psu_init.tcl", text)
        self.assertIn("custom_xczu47dr_slave/hw_platform/hw/psu_init.tcl", text)
        self.assertNotIn("hw_platform/export/hw_platform/hw/psu_init.tcl", text)

    def test_external_250mhz_register_branch_uses_clkin1_and_divide_by_25(self):
        text = HMC7044_VHDL.read_text(encoding="utf-8", errors="ignore")

        expected_writes = (
            'x"0003" & x"2F"',
            'x"0005" & x"5A"',
            'x"0021" & x"19"',
            'x"0026" & x"0A"',
        )
        for write in expected_writes:
            self.assertIn(write, text)

    def test_external_250mhz_selects_high_vco_core_for_3072_ghz(self):
        regs = _hmc7044_registers()

        self.assertEqual(regs[0x0003], 0x2F)
        self.assertEqual((regs[0x0003] >> 3) & 0x3, 0x1)
        self.assertNotEqual((regs[0x0003] >> 3) & 0x3, 0x3)
        self.assertTrue(regs[0x0003] & 0x07 == 0x07)

    def test_external_250mhz_r1_divider_creates_10mhz_pll1_pfd(self):
        text = HMC7044_VHDL.read_text(encoding="utf-8", errors="ignore")
        self.assertRegex(
            text,
            r'if\s+USE_EXTERNAL_250MHZ\s*=\s*\'1\'\s+then\s*'
            r'config_reg\s*<=\s*x"0021"\s*&\s*x"19"',
        )
        self.assertRegex(
            text,
            r'if\s+USE_EXTERNAL_250MHZ\s*=\s*\'1\'\s+then[\s\S]*?'
            r'config_reg\s*<=\s*x"0026"\s*&\s*x"0A"',
        )

        r1 = 0x19
        n1 = 0x0A
        self.assertEqual(250_000_000 / r1, 10_000_000)
        self.assertEqual((250_000_000 / r1) * n1, VCXO_HZ)

    def test_sync_uses_xs17_clkin1_reference(self):
        # XS17(250MHz) 接 CLKIN1；R1=25 产生 10MHz PLL1 PFD。
        text = HMC7044_VHDL.read_text(encoding="utf-8", errors="ignore")
        regs = _hmc7044_registers()

        # 0x0005 有一个历史注释值，解析器会误读；这里直接检查活动写入。
        self.assertIn('config_reg <= x"0005" & x"5A"', text)
        self.assertEqual((0x5A >> 6) & 0x3, 0x1)  # SYNC through PLL2
        self.assertEqual((0x5A >> 1) & 0x1, 1)    # CLKIN1 enabled

        # 0x005B: positive polarity, through PLL2.
        self.assertEqual(regs[0x005B], 0x06)
        self.assertEqual((regs[0x005B] >> 0) & 0x1, 0)  # positive polarity
        self.assertEqual((regs[0x005B] >> 1) & 0x1, 1)  # through PLL2

        # 0x0014: input clock priority restored to the XS17 baseline.
        self.assertEqual(regs[0x0014], 0x36)

    def test_two_board_sync_requires_mts_and_software_sync_gate(self):
        firmware = FIRMWARE_MAIN.read_text(encoding="utf-8", errors="ignore")
        top = TOP_VERILOG.read_text(encoding="utf-8", errors="ignore")
        rfctrl2 = RFCTRL2_RTL.read_text(encoding="utf-8", errors="ignore")
        host = HOST_SOFTWARE.read_text(encoding="utf-8", errors="ignore")

        self.assertIn("XRFdc_MultiConverter_Sync", firmware)
        self.assertIn("SysRef_Enable = 1", firmware)
        self.assertIn("Align_DAC_NCO_To_SYSREF", firmware)
        self.assertIn("FW_STATUS_NCO_SYNC_READY", firmware)
        self.assertIn("Publish_DAC_NCO_Sync_Ready", firmware)
        # 启动阶段不再等待 XS20；运行时由 PL epoch 触发 MTS/NCO 重对齐。
        self.assertIn("SYNC_EVENT_EPOCH_MASK", firmware)
        self.assertIn("HMC7044_SYNC_SETTLE_US", firmware)
        self.assertIn("Reinitialize_RFDC_For_Sync", firmware)
        self.assertIn("Read_Sync_Event_Epoch", firmware)
        self.assertIn("rfctrl2_sync_epoch_pulse", top)
        self.assertIn(".sync_done", top)
        self.assertIn("firmware_nco_sync_ready", top)
        self.assertIn("rfdc_nco_runtime_required", top)
        self.assertIn("dac_mts", rfctrl2.lower())
        self.assertIn("dac_mts", host.lower())
        self.assertIn("RF2_NET_STATUS_HMC_DONE", host)
        self.assertIn("rfctrl2_sync_epoch", host)

    def test_physical_sync_and_trigger_use_hmc_pl_clk_domain(self):
        top = TOP_VERILOG.read_text(encoding="utf-8", errors="ignore")
        sync_link = (REPO_ROOT / "hardware" / "vivado" / "src" / "sync_trigger_link.v").read_text(
            encoding="utf-8", errors="ignore"
        )
        self.assertIn("IBUFDS", top)
        self.assertIn("hmc_pl_clk", top)
        self.assertIn(".hmc_pl_clk", top)
        self.assertIn("input  wire hmc_pl_clk", sync_link)
        self.assertIn(".clk         (hmc_pl_clk)", sync_link)
        self.assertNotIn("trigger_in_pl_sync", sync_link)

    def test_hmc_pl_clk_constraint_matches_96mhz_output(self):
        xdc = (REPO_ROOT / "hardware" / "vivado" / "xdc" / "custom_xczu47dr_minimal.xdc").read_text(
            encoding="utf-8", errors="ignore"
        )
        self.assertIn("create_clock -name PL_CLK_P_0 -period 10.416667", xdc)

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

    def test_pll2_autotune_precedes_settle_and_divider_restart(self):
        text = HMC7044_VHDL.read_text(encoding="utf-8", errors="ignore")

        expected_tail = (
            ("0EF", "0002", "00"),
            ("0F0", "0002", "04"),
            ("0F1", "0002", "00"),
            ("0F2", "0001", "20"),
            ("0F3", "0001", "22"),
            ("0F4", "0001", "20"),
        )
        for count, address, value in expected_tail:
            self.assertRegex(
                text,
                rf'when\s+x"{count}"\s*=>\s*config_reg\s*<=\s*x"{address}"\s*&\s*x"{value}"',
            )

        self.assertRegex(
            text,
            r'config_reg_cnt\s*=\s*x"0F1"\s+then[\s\S]*?spi_cntr_status\s*<=\s*pll2_settle_wait',
        )
        self.assertRegex(
            text,
            r'when\s+pll2_settle_wait\s*=>[\s\S]*?config_reg_cnt\s*<=\s*x"0F2"',
        )

    def test_pll2_settle_wait_is_100_ms_at_25_mhz_state_cadence(self):
        text = HMC7044_VHDL.read_text(encoding="utf-8", errors="ignore")

        self.assertRegex(text, r'PLL2_SETTLE_TICKS\s*:\s*positive\s*:=\s*2500000')
        self.assertIn("integer range 0 to PLL2_SETTLE_TICKS - 1", text)
        self.assertRegex(text, r'pll2_settle_cnt\s*=\s*PLL2_SETTLE_TICKS\s*-\s*1\s+then')
        self.assertAlmostEqual(2_500_000 / 25_000_000, 0.1)

    def test_finish_only_follows_final_divider_restart(self):
        text = HMC7044_VHDL.read_text(encoding="utf-8", errors="ignore")

        self.assertRegex(
            text,
            r'config_reg_cnt\s*=\s*x"0F4"\s+then\s+spi_cntr_status\s*<=\s*config_end',
        )
        config_end = text.index("when config_end =>")
        finish = text.index("SET_FINISH<='1'", config_end)
        self.assertGreater(finish, config_end)


if __name__ == "__main__":
    unittest.main()
