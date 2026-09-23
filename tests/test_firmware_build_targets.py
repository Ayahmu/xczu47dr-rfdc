"""firmware/build.sh 的唯一 waveform target 路径解析测试。"""

import os
import shutil
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
BUILD_SH = REPO_ROOT / "firmware" / "build.sh"

EXPECTED = {
    "custom_xczu47dr_waveform": {
        "ELF": "custom_xczu47dr_waveform.elf",
        "WORKSPACE": "custom_xczu47dr_waveform",
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
        for key in ("ELF", "WORKSPACE", "BOARD_DEFINE"):
            marker = f"{key}="
            if marker in line:
                values.setdefault(key, line.split(marker, 1)[1].strip())
    return values


@unittest.skipUnless(shutil.which("tclsh"), "tclsh not installed")
class FirmwareBuildTargetPathTests(unittest.TestCase):
    def test_every_supported_target_resolves(self):
        """唯一生产目标必须能解析，不能落进 Unsupported TARGET 分支。"""
        for target, expected in EXPECTED.items():
            with self.subTest(target=target):
                values = _resolve(target)
                self.assertEqual(Path(values["ELF"]).name, expected["ELF"])
                self.assertEqual(
                    Path(values["WORKSPACE"]).name, expected["WORKSPACE"]
                )
                self.assertEqual(
                    values["BOARD_DEFINE"], "-DBOARD_CUSTOM_XCZU47DR"
                )

    def test_artifact_dir_override_still_applies(self):
        """ARTIFACT_DIR 覆盖必须仍然生效——修复只取 basename，不能写死路径。"""
        env = dict(
            os.environ,
            TARGET="custom_xczu47dr_waveform",
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
            "/tmp/xczu47dr-artifact-override/custom_xczu47dr_waveform.elf",
            result.stdout,
        )

    def test_allowed_targets_and_build_sh_agree(self):
        """Makefile 的 ALLOWED_TARGETS 和 build.sh 的 case 分支不能脱节。"""
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
