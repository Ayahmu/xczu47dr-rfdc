"""The driver version has one source (dr47/_version.py) and a tool to change it."""

import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOFTWARE = ROOT / "software"
DR47 = SOFTWARE / "dr47"
sys.path.insert(0, str(SOFTWARE))

import bump_driver_version as bump  # noqa: E402


def read_version_file(path: Path) -> str:
    return re.search(r'^__version__\s*=\s*"([^"]+)"', path.read_text(encoding="utf-8"), re.M).group(1)


class VersionSourceTests(unittest.TestCase):
    def test_package_reexports_the_single_source(self):
        import dr47
        self.assertEqual(dr47.__version__, read_version_file(DR47 / "_version.py"))
        init_source = (DR47 / "__init__.py").read_text(encoding="utf-8")
        self.assertNotRegex(init_source, r'__version__\s*=\s*"')  # no second literal

    def test_pyproject_reads_the_version_from_the_same_file(self):
        pyproject = (DR47 / "pyproject.toml").read_text(encoding="utf-8")
        self.assertIsNone(re.search(r'(?m)^version\s*=\s*"', pyproject), "static version literal in pyproject")
        self.assertRegex(pyproject, r'dynamic\s*=\s*\["version"\]')
        self.assertIn('{attr = "dr47._version.__version__"}', pyproject)

    def test_docs_do_not_hard_code_the_version(self):
        current = read_version_file(DR47 / "_version.py")
        for relative in ("docs/API参考.md", "docs/软件版本说明.md", "software/dr47/README.md"):
            text = (ROOT / relative).read_text(encoding="utf-8")
            self.assertNotIn(f"47dr_driver-{current}", text, relative)
            self.assertIsNone(re.search(r"47dr-driver \d+\.\d+\.\d+", text), relative)
            self.assertNotIn(f"`{current}`", text, relative)


class VersionArithmeticTests(unittest.TestCase):
    def test_parts_increment_and_reset_lower_parts(self):
        self.assertEqual(bump.next_version("0.1.0", part="patch"), "0.1.1")
        self.assertEqual(bump.next_version("0.1.9", part="minor"), "0.2.0")
        self.assertEqual(bump.next_version("0.9.9", part="major"), "1.0.0")

    def test_part_bump_needs_a_plain_release_version(self):
        with self.assertRaisesRegex(ValueError, "explicit version"):
            bump.next_version("0.2.0rc1", part="patch")

    def test_valid_and_invalid_explicit_versions(self):
        for good in ("0.2.0", "1.10.3", "2.0.0rc1", "0.3.0a2", "0.3.0b1", "1.0.0.post1", "1.0.0.dev3"):
            self.assertEqual(bump.validate_version(good), good)
        for bad in ("", "1.2", "v1.2.3", "1.2.3.4", "1.2.x", "01.2.3", "1.2.3-rc1", " 1.2.3"):
            with self.assertRaises(ValueError, msg=repr(bad)):
                bump.validate_version(bad)


class VersionFileTests(unittest.TestCase):
    def test_set_version_rewrites_only_the_version_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "_version.py"
            path.write_text('"""doc"""\n\n__version__ = "0.1.0"\n', encoding="utf-8")
            self.assertEqual(bump.set_version(path, "0.2.0"), ("0.1.0", "0.2.0"))
            self.assertEqual(path.read_text(encoding="utf-8"), '"""doc"""\n\n__version__ = "0.2.0"\n')

    def test_unchanged_version_is_rejected_and_file_untouched(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "_version.py"
            path.write_text('__version__ = "0.1.0"\n', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "already"):
                bump.set_version(path, "0.1.0")
            self.assertEqual(path.read_text(encoding="utf-8"), '__version__ = "0.1.0"\n')

    def test_cli_part_and_explicit_version(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "_version.py"
            path.write_text('__version__ = "0.1.0"\n', encoding="utf-8")
            self.assertEqual(bump.main(["--file", str(path), "--part", "minor"]), 0)
            self.assertEqual(read_version_file(path), "0.2.0")
            self.assertEqual(bump.main(["--file", str(path), "3.1.4"]), 0)
            self.assertEqual(read_version_file(path), "3.1.4")
            self.assertNotEqual(bump.main(["--file", str(path), "not-a-version"]), 0)
            self.assertEqual(read_version_file(path), "3.1.4")


@unittest.skipUnless(shutil.which(sys.executable), "python unavailable")
class BuiltWheelTests(unittest.TestCase):
    def test_bumped_version_reaches_the_wheel_name_and_metadata(self):
        try:
            import setuptools, wheel  # noqa: F401,E401
        except ImportError:
            self.skipTest("setuptools/wheel not installed; cannot build offline")
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "dr47src"
            shutil.copytree(DR47, source, ignore=shutil.ignore_patterns(
                "build", "*.egg-info", "__pycache__", "*.pyc", "dist"))
            self.assertEqual(bump.main(["--file", str(source / "_version.py"), "9.8.7"]), 0)
            out = Path(tmp) / "out"
            result = subprocess.run(
                [sys.executable, "-m", "pip", "wheel", "--no-deps", "--no-build-isolation", "-q",
                 "-w", str(out), str(source)],
                capture_output=True, text=True, timeout=300)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            wheels = list(out.glob("*.whl"))
            self.assertEqual([w.name for w in wheels], ["47dr_driver-9.8.7-py3-none-any.whl"])


class CliVersionFlagTests(unittest.TestCase):
    def test_network_cli_reports_the_package_version(self):
        import dr47
        from dr47 import cli
        with self.assertRaises(SystemExit) as raised, unittest.mock.patch("sys.stdout") as out:
            cli.main(["--version"])
        self.assertEqual(raised.exception.code, 0)
        printed = "".join(call.args[0] for call in out.write.call_args_list)
        self.assertIn(dr47.__version__, printed)


import unittest.mock  # noqa: E402

if __name__ == "__main__":
    unittest.main()
