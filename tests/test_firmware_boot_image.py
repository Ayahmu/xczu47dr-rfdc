"""BOOT.BIN 生成、QSPI 烧写和从 QSPI 启动的脚本入口测试。"""

import os
import shutil
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
FIRMWARE = REPO_ROOT / "firmware"
ARTIFACTS = REPO_ROOT / "artifacts"
WORKSPACE = FIRMWARE / "workspace" / "custom_xczu47dr_waveform"
FSBL = WORKSPACE / "hw_platform" / "zynqmp_fsbl" / "fsbl_a53.elf"
PMUFW = WORKSPACE / "hw_platform" / "zynqmp_pmufw" / "pmufw.elf"
WORKSPACE_XSA = WORKSPACE / "hw_platform" / "hw" / "custom_xczu47dr_waveform.xsa"


def _build_sh(command: str, **env) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["./build.sh", command], cwd=FIRMWARE, env=dict(os.environ, **env),
        capture_output=True, text=True, timeout=300)


def _dry_run(command: str, **env) -> str:
    result = _build_sh(command, DRY_RUN="1", ARTIFACT_DIR="/tmp/xczu47dr-boot-test", **env)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout


@unittest.skipUnless(shutil.which("tclsh"), "tclsh not installed")
class BootImageDryRunTests(unittest.TestCase):
    def test_bootbin_packs_fsbl_pmufw_bitstream_and_app_in_boot_order(self):
        out = _dry_run("bootbin")
        self.assertIn("BOOT_BIN=/tmp/xczu47dr-boot-test/BOOT.BIN", out)
        self.assertIn("FSBL_OUT=/tmp/xczu47dr-boot-test/custom_xczu47dr_waveform_fsbl.elf", out)
        order = [out.index(marker) for marker in (
            "[bootloader, destination_cpu=a53-0]", "[pmufw_image]",
            "[destination_device=pl]", "[destination_cpu=a53-0, exception_level=el-3]")]
        self.assertEqual(order, sorted(order))
        self.assertIn("zynqmp_fsbl/fsbl_a53.elf", out)
        self.assertIn("zynqmp_pmufw/pmufw.elf", out)
        self.assertIn("/tmp/xczu47dr-boot-test/custom_xczu47dr_waveform.elf", out)

    def test_flash_writes_boot_bin_to_the_dual_parallel_qspi_and_verifies(self):
        out = _dry_run("flash", JTAG_CABLE_SERIAL="210512180081")
        command = next(line for line in out.splitlines() if "program_flash" in line and " -f " in line)
        for expected in ("-f /tmp/xczu47dr-boot-test/BOOT.BIN",
                         "-fsbl /tmp/xczu47dr-boot-test/custom_xczu47dr_waveform_fsbl.elf",
                         "-flash_type qspi-x8-dual_parallel", "-flash_density 512", "-offset 0", "-verify"):
            self.assertIn(expected, command)
        # The flash is written with the PS parked in JTAG boot mode.
        self.assertIn("boot_mode.tcl jtag", out)
        self.assertLess(out.index("boot_mode.tcl jtag"), out.index(command))

    def test_flash_parameters_can_be_overridden(self):
        out = _dry_run("flash", QSPI_FLASH_TYPE="qspi-x4-single", QSPI_FLASH_DENSITY="256")
        self.assertIn("-flash_type qspi-x4-single", out)
        self.assertIn("-flash_density 256", out)

    def test_boot_qspi_restarts_the_board_from_flash(self):
        out = _dry_run("boot-qspi")
        self.assertIn("boot_mode.tcl qspi", out)

    def test_unknown_command_lists_the_new_ones(self):
        result = _build_sh("no-such-command")
        self.assertNotEqual(result.returncode, 0)
        for command in ("bootbin", "flash", "boot-qspi"):
            self.assertIn(command, result.stdout)


class BootImageWiringTests(unittest.TestCase):
    def test_makefile_exposes_the_boot_targets(self):
        makefile = (REPO_ROOT / "Makefile").read_text(encoding="utf-8")
        for target, command in (("bootbin", "bootbin"), ("flash", "flash"), ("boot-qspi", "boot-qspi")):
            self.assertRegex(makefile, rf"(?m)^{target}:\n\tcd \$\(FIRMWARE_DIR\).*\./build\.sh {command}$")
        phony = next(line for line in makefile.splitlines() if line.startswith(".PHONY:"))
        for target in ("bootbin", "flash", "boot-qspi"):
            self.assertIn(f" {target}", phony)

    def test_boot_image_and_fsbl_are_hashed_and_tracked(self):
        makefile = (REPO_ROOT / "Makefile").read_text(encoding="utf-8")
        hash_rule = makefile.split("artifacts-hash:", 1)[1].split("artifacts-clean:", 1)[0]
        for name in ("custom_xczu47dr_waveform.xsa", "custom_xczu47dr_waveform.elf",
                     "BOOT.BIN", "custom_xczu47dr_waveform_fsbl.elf"):
            self.assertIn(name, hash_rule)
        ignore = (REPO_ROOT / ".gitignore").read_text(encoding="utf-8")
        self.assertIn("!/artifacts/BOOT.BIN", ignore)
        self.assertIn("!/artifacts/custom_xczu47dr_waveform_fsbl.elf", ignore)

    def test_boot_image_follows_every_firmware_and_hardware_build(self):
        """BOOT.BIN must never be older than the ELF or the XSA it was packed from."""
        makefile = (REPO_ROOT / "Makefile").read_text(encoding="utf-8")

        def recipe(target: str) -> str:
            return makefile.split(f"\n{target}:", 1)[1].split("\n\n", 1)[0]

        for target in ("firmware", "firmware-build"):
            lines = recipe(target)
            self.assertLess(lines.index("./build.sh build"), lines.index("./build.sh bootbin"), target)
        # A new XSA makes the old boot image wrong until the firmware is rebuilt.
        for target in ("hardware", "hardware-fast", "xsa"):
            lines = recipe(target)
            self.assertIn("BOOT.BIN", lines, target)
            self.assertIn("_fsbl.elf", lines, target)

    def test_boot_mode_script_uses_the_alternate_boot_mode_register(self):
        script = (FIRMWARE / "scripts" / "boot_mode.tcl").read_text(encoding="utf-8")
        self.assertIn("0xFF5E0200", script)          # CRL_APB.BOOT_MODE_USER
        self.assertIn("0xFF5E0204", script)          # CRL_APB.BOOT_MODE_POR: the mode pins
        self.assertIn("0x2100", script)              # QSPI32, use_alt
        self.assertIn("0x0100", script)              # JTAG, use_alt
        self.assertIn("rst -system", script)
        self.assertIn("JTAG_CABLE_SERIAL", script)

    def test_jtag_programming_does_not_race_a_flash_boot(self):
        """With the mode pins on QSPI a system reset would start the flash image
        while program.tcl loads its own; it must select JTAG boot first."""
        script = (FIRMWARE / "scripts" / "program.tcl").read_text(encoding="utf-8")
        select = script.index("mwr 0xFF5E0200 0x0100")
        self.assertLess(select, script.index("rst -system", select))


FAKE_PROGRAM_FLASH = """#!/bin/bash
# Stand-in for the Vitis tool: answers the target listing and plays back the
# outcomes listed in $FAKE_FLASH_OUTCOMES, one per flash attempt.
if [ "$1" = "-jtagtargets" ]; then
    echo "1  Digilent/210512180081/"
    echo "   2  jsn-JTAG-HS1-210512180081-147ff093-0  (name xczu47dr  idcode 147ff093)"
    echo "   3  jsn-JTAG-HS1-210512180081-5ba00477-0  (name arm_dap  idcode 5ba00477)"
    echo "4  Digilent/999999999999/"
    echo "   5  jsn-JTAG-HS1-999999999999-5ba00477-0  (name arm_dap  idcode 5ba00477)"
    exit 0
fi
echo "$*" >> "$FAKE_FLASH_CALLS"
attempt=$(wc -l < "$FAKE_FLASH_CALLS")
case "$(echo $FAKE_FLASH_OUTCOMES | cut -d' ' -f$attempt)" in
    ok)      echo "Verify Operation successful."; echo "Flash Operation Successful"; exit 0 ;;
    init)    echo "Problem in running uboot"; echo "Flash programming initialization failed."
             echo "ERROR: Flash Operation Failed"; exit 1 ;;
    *)       echo "Verify Operation unsuccessful."; echo "ERROR: Flash Operation Failed"; exit 1 ;;
esac
"""


@unittest.skipUnless(shutil.which("tclsh"), "tclsh not installed")
class FlashToolHandlingTests(unittest.TestCase):
    """build.sh flash against a stand-in program_flash and xsct."""

    def _flash(self, outcomes: str):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            tools, artifact_dir = tmp / "bin", tmp / "artifacts"
            tools.mkdir()
            artifact_dir.mkdir()
            (artifact_dir / "BOOT.BIN").write_bytes(b"boot image")
            (artifact_dir / "custom_xczu47dr_waveform_fsbl.elf").write_bytes(b"fsbl")
            (tools / "program_flash").write_text(FAKE_PROGRAM_FLASH)
            (tools / "xsct").write_text("#!/bin/bash\nexit 0\n")
            for tool in tools.iterdir():
                tool.chmod(0o755)
            calls = tmp / "calls"
            calls.touch()
            result = _build_sh(
                "flash", ARTIFACT_DIR=str(artifact_dir), JTAG_CABLE_SERIAL="210512180081",
                PATH=f"{tools}:{os.environ['PATH']}", FAKE_FLASH_CALLS=str(calls), FAKE_FLASH_OUTCOMES=outcomes)
            return result, calls.read_text().splitlines()

    def test_flash_addresses_the_board_on_the_selected_cable(self):
        result, calls = self._flash("ok")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertIn("-target_name jsn-JTAG-HS1-210512180081-5ba00477-0", calls[0])

    def test_flash_repeats_when_the_tool_fails_before_touching_the_flash(self):
        """program_flash starts its helper after a fixed wait and sometimes finds it
        not answering (seen on the board, about one start in ten).  Nothing is
        erased at that point."""
        result, calls = self._flash("init init ok")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 3)

    def test_flash_gives_up_after_three_failed_starts(self):
        result, calls = self._flash("init init init ok")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 3)

    def test_flash_does_not_repeat_a_failed_write(self):
        result, calls = self._flash("verify ok")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)


@unittest.skipUnless(
    shutil.which("bootgen") and FSBL.exists() and PMUFW.exists() and WORKSPACE_XSA.exists()
    and (ARTIFACTS / "custom_xczu47dr_waveform.xsa").exists(),
    "needs bootgen and a built firmware workspace")
class BootImageBuildTests(unittest.TestCase):
    def _artifact_dir(self, tmp: Path) -> Path:
        for name in ("custom_xczu47dr_waveform.xsa", "custom_xczu47dr_waveform.elf"):
            shutil.copy(ARTIFACTS / name, tmp / name)
        return tmp

    def test_bootbin_builds_a_zynqmp_image_with_all_four_parts(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            artifact_dir = self._artifact_dir(Path(tmp))
            if (artifact_dir / "custom_xczu47dr_waveform.xsa").read_bytes() != WORKSPACE_XSA.read_bytes():
                self.skipTest("firmware workspace was built from another XSA")
            result = _build_sh("bootbin", ARTIFACT_DIR=str(artifact_dir))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            image = (artifact_dir / "BOOT.BIN").read_bytes()
            self.assertEqual(image[0x24:0x28], b"XNLX")
            self.assertGreater(int.from_bytes(image[0x34:0x38], "little"), 0, "PMU firmware missing")
            self.assertGreater(len(image), 30 << 20, "bitstream missing")
            fsbl = (artifact_dir / "custom_xczu47dr_waveform_fsbl.elf").read_bytes()
            self.assertEqual(fsbl[:4], b"\x7fELF")
            self.assertNotIn(b".debug_info", fsbl)       # published stripped
            self.assertLess(len(fsbl), FSBL.stat().st_size)
            self.assertEqual(sorted(p.name for p in artifact_dir.iterdir()), [
                "BOOT.BIN", "custom_xczu47dr_waveform.elf",
                "custom_xczu47dr_waveform.xsa", "custom_xczu47dr_waveform_fsbl.elf"])

    def test_bootbin_refuses_an_fsbl_built_from_another_xsa(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            artifact_dir = self._artifact_dir(Path(tmp))
            with open(artifact_dir / "custom_xczu47dr_waveform.xsa", "ab") as xsa:
                xsa.write(b"\0")
            result = _build_sh("bootbin", ARTIFACT_DIR=str(artifact_dir))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("make firmware", result.stdout + result.stderr)
            self.assertFalse((artifact_dir / "BOOT.BIN").exists())


if __name__ == "__main__":
    unittest.main()
