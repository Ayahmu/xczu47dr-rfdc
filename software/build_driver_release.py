#!/usr/bin/env python3
"""Assemble the binary wheels, documentation, and examples into one SDK ZIP.

The wheels come from ``build_driver_wheels.py`` (``make driver-wheel``): one
per supported Python version, compiled modules only.  This script refuses to
bundle anything else.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DIST_DIR = ROOT / "dist"
PACKAGE_DIR = ROOT / "software" / "dr47"
EXAMPLES_DIR = PACKAGE_DIR / "examples"

sys.path.insert(0, str(ROOT / "software"))
import build_driver_wheels  # noqa: E402
from dr47 import RFCTRL2_VERSION, __version__  # noqa: E402


DOCUMENTS = (
    ROOT / "docs" / "软件版本说明.md",
    ROOT / "docs" / "API参考.md",
    ROOT / "docs" / "硬件指标.md",
    ROOT / "software" / "dr47" / "README.md",
)
EXAMPLES = tuple(
    sorted(path for path in EXAMPLES_DIR.glob("*.py") if path.name != "__init__.py")
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _tag(wheel: Path) -> str:
    return wheel.name.split("-")[2]


def release_wheels() -> list[Path]:
    """The binary wheels of this version, one per supported Python, all checked."""
    wheels = build_driver_wheels.built_wheels()
    missing = [tag for tag in build_driver_wheels.PYTHON_TAGS if tag not in {_tag(wheel) for wheel in wheels}]
    if missing:
        raise FileNotFoundError(
            f"binary wheels of version {__version__} for {' '.join(missing)} not found in "
            f"{build_driver_wheels.DIST_DIR}; run 'make driver-wheel'"
        )
    for wheel in wheels:
        problems = build_driver_wheels.wheel_problems(wheel)
        if problems:
            raise RuntimeError(f"{wheel.name} is not releasable: " + "; ".join(problems))
    return wheels


def smoke_test(wheels: list[Path]) -> None:
    """Install the wheel of the running interpreter on its own and run the simulator example."""
    tag = f"cp{sys.version_info.major}{sys.version_info.minor}"
    wheel = next((wheel for wheel in wheels if _tag(wheel) == tag), None)
    if wheel is None:
        print(f"note: no wheel for this interpreter ({tag}); every wheel was already tried in the build container")
        return
    smoke = (
        "import runpy, sys; "
        "sys.path.insert(0, sys.argv[1]); "
        "import dr47; "
        "assert dr47.__file__.startswith(sys.argv[1]), dr47.__file__; "
        "assert dr47.device.__file__.endswith('.so'), dr47.device.__file__; "
        "runpy.run_module('dr47.examples.simulator_quickstart', run_name='__main__')"
    )
    environment = os.environ.copy()
    environment.pop("PYTHONPATH", None)
    with tempfile.TemporaryDirectory() as target:
        subprocess.run(
            [sys.executable, "-m", "pip", "install", "--quiet", "--no-deps", "--target", target, str(wheel)],
            env=environment, check=True,
        )
        subprocess.run(
            [sys.executable, "-I", "-c", smoke, target],
            cwd=tempfile.gettempdir(), env=environment, check=True,
        )


def build_bundle(wheels: list[Path]) -> Path:
    missing = [path for path in (*DOCUMENTS, *EXAMPLES) if not path.is_file()]
    if missing:
        raise FileNotFoundError(f"release input missing: {missing[0]}")

    bundle_name = f"47dr-driver-sdk-{__version__}"
    archive_path = DIST_DIR / f"{bundle_name}.zip"
    payloads: list[tuple[str, bytes]] = []
    for wheel in wheels:
        payloads.append((f"packages/{wheel.name}", wheel.read_bytes()))
    for path in DOCUMENTS:
        relative = path.relative_to(ROOT)
        payloads.append((relative.as_posix(), path.read_bytes()))
    for path in EXAMPLES:
        payloads.append((f"examples/{path.name}", path.read_bytes()))

    checksums = "".join(
        f"{sha256(data)}  {name}\n" for name, data in payloads
    ).encode("utf-8")
    manifest = json.dumps(
        {
            "distribution": "47dr-driver",
            "driver_version": __version__,
            "rfctrl2_protocol_version": RFCTRL2_VERSION,
            "python_versions": [f"{tag[2]}.{tag[3:]}" for tag in (_tag(wheel) for wheel in wheels)],
            "platform": "Linux x86-64, glibc 2.17 or newer",
            "runtime_dependencies": ["numpy>=1.23"],
            "install": "python -m pip install --find-links packages 47dr-driver",
            "supported_scope": [
                "board discovery and network provisioning",
                "RFDC and output-channel configuration",
                "waveform generation and DDR upload",
                "finite burst scheduling",
                "software and external Trigger playback",
                "in-memory simulation",
            ],
            "excluded_features": [
                "TDC calibration, compensation, diagnostics, and public API"
            ],
            "generated_utc": datetime.now(timezone.utc).isoformat(),
            "wheels": [wheel.name for wheel in wheels],
            "documents": [path.relative_to(ROOT).as_posix() for path in DOCUMENTS],
            "examples": [path.name for path in EXAMPLES],
        },
        ensure_ascii=True,
        indent=2,
    ).encode("utf-8") + b"\n"

    with zipfile.ZipFile(
        archive_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
    ) as archive:
        for name, data in payloads:
            archive.writestr(f"{bundle_name}/{name}", data)
        archive.writestr(f"{bundle_name}/SHA256SUMS", checksums)
        archive.writestr(f"{bundle_name}/MANIFEST.json", manifest)

    external_checksums = DIST_DIR / "SHA256SUMS"
    external_checksums.write_text(
        "".join(f"{sha256(wheel.read_bytes())}  {wheel.name}\n" for wheel in wheels)
        + f"{sha256(archive_path.read_bytes())}  {archive_path.name}\n",
        encoding="ascii",
    )
    return archive_path


def main() -> int:
    wheels = release_wheels()
    smoke_test(wheels)
    archive_path = build_bundle(wheels)
    print(f"SDK bundle: {archive_path}")
    print(f"Checksums:  {DIST_DIR / 'SHA256SUMS'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
