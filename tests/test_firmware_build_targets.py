"""firmware/build.sh 的目标路径解析测试。

custom_xczu47dr_slave_trigout 和 custom_xczu47dr_slave 只差 PL generics
（XS20 作为第二路 Trigger 输出），所以它有自己的 .bit，但复用 slave 的 workspace、
ELF 和 psu_init。build.sh 原来把 ELF/psu_init 从 output_basename 推导，指向了
custom_xczu47dr_slave_trigout.elf 这种根本不会生成的文件；而且 case 分支里漏了这个
目标，直接报 "Unsupported TARGET"。两个问题都是在板上烧写时才暴露的。
"""

import os
import shutil
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
BUILD_SH = REPO_ROOT / "firmware" / "build.sh"

EXPECTED = {
    "custom_xczu47dr_master": {
        "BIT": "custom_xczu47dr_master.bit",
        "ELF": "custom_xczu47dr_master.elf",
        "PSU_INIT": "custom_xczu47dr_master_psu_init.tcl",
        "WORKSPACE": "custom_xczu47dr_master",
    },
    "custom_xczu47dr_slave": {
        "BIT": "custom_xczu47dr_slave.bit",
        "ELF": "custom_xczu47dr_slave.elf",
        "PSU_INIT": "custom_xczu47dr_slave_psu_init.tcl",
        "WORKSPACE": "custom_xczu47dr_slave",
    },
    # 自己的 bit，slave 的固件
    "custom_xczu47dr_slave_trigout": {
        "BIT": "custom_xczu47dr_slave_trigout.bit",
        "ELF": "custom_xczu47dr_slave.elf",
        "PSU_INIT": "custom_xczu47dr_slave_psu_init.tcl",
        "WORKSPACE": "custom_xczu47dr_slave",
    },
}


def _resolve(target: str) -> dict:
    env = dict(os.environ, TARGET=target, DRY_RUN="1")
    result = subprocess.run(
        ["./build.sh", "program"],
        cwd=REPO_ROOT / "firmware",
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"build.sh failed for TARGET={target}:\n{result.stdout}\n{result.stderr}"
        )
    values = {}
    for line in result.stdout.splitlines():
        for key in ("BIT", "ELF", "PSU_INIT", "WORKSPACE", "BOARD_DEFINE"):
            marker = f"{key}="
            if marker in line:
                values.setdefault(key, line.split(marker, 1)[1].strip())
    return values


@unittest.skipUnless(shutil.which("tclsh"), "tclsh not installed")
class FirmwareBuildTargetPathTests(unittest.TestCase):
    def test_every_supported_target_resolves(self):
        """三个目标都必须能解析，不能落进 Unsupported TARGET 分支。"""
        for target, expected in EXPECTED.items():
            with self.subTest(target=target):
                values = _resolve(target)
                self.assertEqual(Path(values["BIT"]).name, expected["BIT"])
                self.assertEqual(Path(values["ELF"]).name, expected["ELF"])
                self.assertEqual(
                    Path(values["PSU_INIT"]).name, expected["PSU_INIT"]
                )
                self.assertEqual(
                    Path(values["WORKSPACE"]).name, expected["WORKSPACE"]
                )
                self.assertEqual(
                    values["BOARD_DEFINE"], "-DBOARD_CUSTOM_XCZU47DR"
                )

    def test_trigout_reuses_slave_firmware_but_keeps_its_own_bitstream(self):
        """trigout 的 bit 必须是自己的，ELF/psu_init 必须是 slave 的。

        这正是原来的 bug：ELF 从 output_basename 推导出
        custom_xczu47dr_slave_trigout.elf，那个文件永远不存在。
        """
        trigout = _resolve("custom_xczu47dr_slave_trigout")
        slave = _resolve("custom_xczu47dr_slave")
        self.assertNotEqual(trigout["BIT"], slave["BIT"])
        self.assertEqual(trigout["ELF"], slave["ELF"])
        self.assertEqual(trigout["PSU_INIT"], slave["PSU_INIT"])
        self.assertEqual(trigout["WORKSPACE"], slave["WORKSPACE"])

    def test_artifact_dir_override_still_applies(self):
        """ARTIFACT_DIR 覆盖必须仍然生效——修复只取 basename，不能写死路径。"""
        env = dict(
            os.environ,
            TARGET="custom_xczu47dr_slave_trigout",
            DRY_RUN="1",
            ARTIFACT_DIR="/tmp/xczu47dr-artifact-override",
        )
        result = subprocess.run(
            ["./build.sh", "program"],
            cwd=REPO_ROOT / "firmware",
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "/tmp/xczu47dr-artifact-override/custom_xczu47dr_slave.elf",
            result.stdout,
        )

    def test_allowed_targets_and_build_sh_agree(self):
        """Makefile 的 ALLOWED_TARGETS 和 build.sh 的 case 分支不能脱节。

        当初就是只加了 Makefile 和 target_config.tcl，漏了 build.sh。
        """
        makefile = (REPO_ROOT / "Makefile").read_text(encoding="utf-8")
        allowed = []
        for line in makefile.splitlines():
            if line.startswith("ALLOWED_TARGETS"):
                allowed = line.split(":=", 1)[1].split()
                break
        self.assertTrue(allowed, "ALLOWED_TARGETS not found in Makefile")
        script = BUILD_SH.read_text(encoding="utf-8")
        for target in allowed:
            with self.subTest(target=target):
                self.assertIn(target, script)


if __name__ == "__main__":
    unittest.main()
