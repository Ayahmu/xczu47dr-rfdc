"""check_xdc_pins.tcl 的离线测试。

这个检查脚本平时只在 Vivado 里、对着综合后的 checkpoint 运行，所以它自己的错误
要等构建跑进去十分钟后才暴露——曾经因为注释里一个孤立的左花括号（Tcl 连注释里的
花括号也计数）让整个 foreach 解析失败，白掉一次双目标构建。这里用 tclsh 加桩把它
在毫秒级跑完，覆盖三件事：脚本能解析、活的名字判成活、死的名字判成死并且退出码
非零。
"""

import shutil
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
HARNESS = Path(__file__).resolve().parent / "check_xdc_pins_harness.tcl"
CHECKER = REPO_ROOT / "hardware" / "vivado" / "scripts" / "check_xdc_pins.tcl"


def _run(case: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["tclsh", str(HARNESS), str(REPO_ROOT), case],
        capture_output=True,
        text=True,
        timeout=120,
    )


@unittest.skipUnless(shutil.which("tclsh"), "tclsh not installed")
class CheckXdcPinsTests(unittest.TestCase):
    def test_script_parses_and_passes_when_every_object_exists(self):
        """全部对象都在时，检查脚本必须退出 0，并分别报出 pin/clock 两行统计。"""
        result = _run("live")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("XDC pin check:", result.stdout)
        self.assertIn("XDC clock check:", result.stdout)
        self.assertIn("0 dead", result.stdout)
        self.assertNotIn("missing close-brace", result.stderr)

    def test_dead_clock_name_inside_a_braced_list_is_reported(self):
        """花括号列表里死掉一个名字就必须报出来——同列表里还有活名字也不能掩盖。

        这正是 clk_out1_design_1_clk_wiz_dac_axis_0_0 长期没被发现的原因：
        get_clocks 整体返回非空，Vivado 不报警。
        """
        result = _run("dead")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("dead XDC clock name", result.stdout)
        self.assertIn("RFDAC2_CLK", result.stdout)

    def test_no_unbalanced_brace_in_any_comment(self):
        """braced body 里的注释花括号必须配平，否则 Tcl 解析整块都会失败。"""
        offenders = []
        for number, line in enumerate(
            CHECKER.read_text(encoding="utf-8").splitlines(), start=1
        ):
            stripped = line.strip()
            if not stripped.startswith("#"):
                continue
            if stripped.count("{") != stripped.count("}"):
                offenders.append(f"{number}: {stripped}")
        self.assertEqual(offenders, [], "unbalanced braces in comments")

    def test_makefile_surfaces_the_clock_findings(self):
        """Makefile 的 grep 必须同时捞出 clock 的统计和死名字，否则失败原因看不见。"""
        makefile = (REPO_ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn("XDC (pin|clock) check:", makefile)
        self.assertIn("dead XDC (pin pattern|clock name)", makefile)


if __name__ == "__main__":
    unittest.main()
