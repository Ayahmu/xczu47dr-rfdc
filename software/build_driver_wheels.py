#!/usr/bin/env python3
"""Build the binary driver wheels: compiled modules, one wheel per Python version.

The package is copied into a staging tree, compiled with Cython inside the
manylinux container and written to ``dist/``.  The wheels carry extension
modules instead of the Python sources and a prebuilt UDP sender core, so the
target host needs neither the sources nor a C compiler.  Built against glibc
2.28 they load on Ubuntu 20.04, Debian 10, RHEL 8 and anything newer (x86-64).

    python software/build_driver_wheels.py                 # every supported Python
    python software/build_driver_wheels.py --python cp312  # one of them

Every wheel is installed in the container, runs the simulator example and the
driver tests, and is checked for leftover sources before it is accepted.

Needs Docker and network access (the build pulls setuptools, Cython, numpy
and pytest).
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIST_DIR = ROOT / "dist"
PACKAGE_DIR = ROOT / "software" / "dr47"
PACKAGING_DIR = ROOT / "software" / "packaging"

sys.path.insert(0, str(ROOT / "software"))
from dr47._version import __version__  # noqa: E402

IMAGE = os.environ.get("DR47_WHEEL_IMAGE", "quay.io/pypa/manylinux_2_28_x86_64")
PLATFORM = "manylinux_2_28_x86_64"
PYTHON_TAGS = ("cp310", "cp311", "cp312", "cp313", "cp314")
# Research code that is not part of the delivered API.
EXCLUDED_MODULES = frozenset({"tdc"})
# Shipped as Python: the import surface and the version number.
PLAIN_MODULES = frozenset({"__init__", "_version"})
# Driver tests that hold for an installed wheel as well; the container runs
# them against every wheel it builds.  The remaining driver tests cover the
# source tree and its tooling.
WHEEL_TESTS = (
    "test_waveform_protocol_v2.py", "test_waveform_public_api.py", "test_wave_image_packing.py",
    "test_wave_bulk_upload.py", "test_playback.py", "test_iq_amplitude_normalized.py",
    "test_example_imports.py", "test_example_scripts.py",
)


def compiled_modules() -> list[str]:
    return sorted(path.stem for path in PACKAGE_DIR.glob("*.py")
                  if path.stem not in PLAIN_MODULES | EXCLUDED_MODULES)


def _replace_once(text: str, pattern: str, replacement: str) -> str:
    result, count = re.subn(pattern, replacement, text, flags=re.M)
    if count != 1:
        raise RuntimeError(f"pyproject.toml: expected one match for {pattern!r}, found {count}")
    return result


def staged_pyproject(text: str) -> str:
    """pyproject.toml of the binary build, derived from the package's own."""
    text = _replace_once(text, r'^requires = \["setuptools>=68", "wheel"\]$',
                         'requires = ["setuptools>=68", "wheel", "Cython>=3.1,<4"]')
    # The staged tree has the usual layout: the package in its own directory.
    text = _replace_once(text, r'^(\[tool\.setuptools\.package-dir\]\n)dr47 = "\."$', r'\1dr47 = "dr47"')
    # No link back to the source repository, and no C source in the wheel.
    text = _replace_once(text, r"^\[project\.urls\]\n(?:.+\n)+\n", "")
    text = _replace_once(text, r"^(?:#.*\n)*\[tool\.setuptools\.package-data\]\n(?:.+\n)+\n", "")
    text = _replace_once(text, r'^(\[tool\.setuptools\]\n)', r"\1include-package-data = false\n")
    return text


def stage(destination: Path) -> None:
    """Copy what the binary build needs into ``destination``."""
    package = destination / "dr47"
    (package / "examples").mkdir(parents=True)
    for path in sorted(PACKAGE_DIR.glob("*.py")):
        if path.stem not in EXCLUDED_MODULES:
            shutil.copy(path, package / path.name)
    for path in sorted((PACKAGE_DIR / "examples").glob("*.py")):
        shutil.copy(path, package / "examples" / path.name)
    # C sources stay outside the package directory so that nothing can pick
    # them up as package data.
    (destination / "csrc").mkdir()
    shutil.copy(PACKAGE_DIR / "_fastsend.c", destination / "csrc" / "_fastsend.c")
    # Only the number: the docstring of the original describes repository tooling.
    (package / "_version.py").write_text(f'__version__ = "{__version__}"\n', encoding="utf-8")
    shutil.copy(PACKAGE_DIR / "README.md", destination / "README.md")
    (destination / "pyproject.toml").write_text(
        staged_pyproject((PACKAGE_DIR / "pyproject.toml").read_text(encoding="utf-8")), encoding="utf-8")
    shutil.copy(PACKAGING_DIR / "setup_binary.py", destination / "setup.py")


def wheel_problems(wheel: Path) -> list[str]:
    """What keeps ``wheel`` from being a releasable binary wheel; empty when it is one."""
    with zipfile.ZipFile(wheel) as archive:
        names = archive.namelist()
        metadata = "\n".join(archive.read(name).decode("utf-8", "replace")
                             for name in names if name.endswith(".dist-info/METADATA"))
    problems = []
    if not re.fullmatch(rf"47dr_driver-{re.escape(__version__)}-(cp3\d+)-\1-[\w.]*{PLATFORM}[\w.]*\.whl", wheel.name):
        problems.append(f"not a CPython {PLATFORM} wheel of version {__version__}")
    modules = [name for name in names if name.startswith("dr47/") and name.count("/") == 1]
    for name in modules:
        stem = name[len("dr47/"):].split(".", 1)[0]
        if stem in EXCLUDED_MODULES:
            problems.append(f"excluded module shipped: {name}")
        elif name.endswith((".py", ".pyx", ".pxd", ".c", ".h")) and stem not in PLAIN_MODULES:
            problems.append(f"source shipped: {name}")
    for module in (*compiled_modules(), "_fastsend"):
        if not any(re.fullmatch(rf"dr47/{module}\.[\w.-]+\.so", name) for name in names):
            problems.append(f"compiled module missing: dr47/{module}")
    if "github.com" in metadata:
        problems.append("metadata links to the source repository")
    return problems


def built_wheels(tags=PYTHON_TAGS) -> list[Path]:
    return sorted(wheel for tag in tags
                  for wheel in DIST_DIR.glob(f"47dr_driver-{__version__}-{tag}-{tag}-*{PLATFORM}*.whl"))


def build(tags: tuple[str, ...]) -> list[Path]:
    if shutil.which("docker") is None:
        raise RuntimeError("docker not found: the wheels are built inside the manylinux image")
    DIST_DIR.mkdir(exist_ok=True)
    for stale in built_wheels(tags):
        stale.unlink()
    with tempfile.TemporaryDirectory(prefix="dr47-wheel-") as temporary:
        staged, out = Path(temporary) / "src", Path(temporary) / "out"
        staged.mkdir()
        out.mkdir()
        stage(staged)
        os.chmod(temporary, 0o755)        # the container user is this uid, but be explicit
        subprocess.run([
            "docker", "run", "--rm", "--user", f"{os.getuid()}:{os.getgid()}",
            "-e", f"PYTHON_TAGS={' '.join(tags)}", "-e", f"AUDITWHEEL_PLAT={PLATFORM}",
            "-e", "DRIVER_TESTS=" + " ".join(f"/repo/tests/{name}" for name in WHEEL_TESTS),
            "-v", f"{staged}:/src:ro", "-v", f"{out}:/out", "-v", f"{ROOT}:/repo:ro",
            "-v", f"{PACKAGING_DIR / 'build_in_container.sh'}:/build_in_container.sh:ro",
            IMAGE, "bash", "/build_in_container.sh"], check=True)
        for wheel in sorted(out.glob("*.whl")):
            shutil.copy(wheel, DIST_DIR / wheel.name)
    wheels = built_wheels(tags)
    if len(wheels) != len(tags):
        raise RuntimeError(f"expected {len(tags)} wheels, found {[wheel.name for wheel in wheels]}")
    for wheel in wheels:
        problems = wheel_problems(wheel)
        if problems:
            raise RuntimeError(f"{wheel.name}: " + "; ".join(problems))
    return wheels


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--python", nargs="+", default=list(PYTHON_TAGS), choices=PYTHON_TAGS, metavar="TAG",
                        help=f"interpreter tags to build for (default: {' '.join(PYTHON_TAGS)})")
    arguments = parser.parse_args()
    for wheel in build(tuple(arguments.python)):
        print(f"wheel: {wheel}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
