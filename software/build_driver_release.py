#!/usr/bin/env python3
"""Assemble the built wheel, documentation, and examples into one SDK ZIP."""

from __future__ import annotations

import base64
import csv
import hashlib
import io
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
from dr47 import RFCTRL2_VERSION, __version__  # noqa: E402


DOCUMENTS = (
    ROOT / "docs" / "驱动SDK交付指南.md",
    ROOT / "docs" / "API参考.md",
    ROOT / "docs" / "使用与测试指南.md",
    ROOT / "docs" / "硬件验收.md",
    ROOT / "software" / "dr47" / "README.md",
)
EXAMPLES = tuple(
    sorted(path for path in EXAMPLES_DIR.glob("*.py") if path.name != "__init__.py")
)
EXCLUDED_WHEEL_MEMBERS = frozenset({"dr47/tdc.py"})


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def find_wheel() -> Path:
    wheels = sorted(
        DIST_DIR.glob(f"47dr_driver-{__version__}-py3-none-any.whl"),
        key=lambda path: path.stat().st_mtime_ns,
    )
    if not wheels:
        raise FileNotFoundError(
            f"driver wheel for version {__version__} not found in {DIST_DIR}"
        )
    return wheels[-1]


def wheel_hash(data: bytes) -> str:
    """Return the urlsafe, unpadded SHA-256 form required by wheel RECORD."""

    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=")
    return f"sha256={digest.decode('ascii')}"


def remove_unsupported_modules(wheel: Path) -> None:
    """Remove unsupported public modules and rebuild the wheel RECORD.

    ``setuptools`` discovers every module in ``dr47``.  TDC remains available in
    the source tree for future work, but it is deliberately removed from this
    release artifact so the installed package cannot expose an unsupported API.
    The wheel RECORD must be regenerated after changing ZIP members or pip will
    report a corrupt/incomplete installation.
    """

    with zipfile.ZipFile(wheel, "r") as source:
        entries = [
            (item, source.read(item.filename))
            for item in source.infolist()
            if item.filename not in EXCLUDED_WHEEL_MEMBERS
        ]

    names = {item.filename for item, _ in entries}
    record_names = [name for name in names if name.endswith(".dist-info/RECORD")]
    if len(record_names) != 1:
        raise RuntimeError(f"expected one wheel RECORD, found {record_names}")
    record_name = record_names[0]
    entries = [(item, data) for item, data in entries if item.filename != record_name]

    record_buffer = io.StringIO(newline="")
    writer = csv.writer(record_buffer, lineterminator="\n")
    for item, data in sorted(entries, key=lambda entry: entry[0].filename):
        writer.writerow((item.filename, wheel_hash(data), len(data)))
    writer.writerow((record_name, "", ""))
    record_data = record_buffer.getvalue().encode("utf-8")

    record_info = zipfile.ZipInfo(record_name)
    record_info.compress_type = zipfile.ZIP_DEFLATED
    record_info.external_attr = 0o100644 << 16
    entries.append((record_info, record_data))

    with tempfile.NamedTemporaryFile(
        prefix=f".{wheel.stem}-", suffix=".whl", dir=wheel.parent, delete=False
    ) as temporary:
        temporary_path = Path(temporary.name)
    try:
        with zipfile.ZipFile(
            temporary_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
        ) as target:
            for item, data in entries:
                target.writestr(item, data)
        temporary_path.replace(wheel)
    finally:
        temporary_path.unlink(missing_ok=True)


def verify_release_wheel(wheel: Path) -> None:
    with zipfile.ZipFile(wheel, "r") as archive:
        names = set(archive.namelist())
    leaked = sorted(EXCLUDED_WHEEL_MEMBERS & names)
    if leaked:
        raise RuntimeError(f"unsupported modules remain in release wheel: {leaked}")

    smoke = (
        "import runpy, sys; "
        "sys.path.insert(0, sys.argv[1]); "
        "import dr47; "
        "assert '.whl/' in dr47.__file__, dr47.__file__; "
        "runpy.run_module('dr47.examples.simulator_quickstart', run_name='__main__')"
    )
    environment = os.environ.copy()
    environment.pop("PYTHONPATH", None)
    subprocess.run(
        [sys.executable, "-I", "-c", smoke, str(wheel.resolve())],
        cwd=tempfile.gettempdir(),
        env=environment,
        check=True,
    )


def main() -> int:
    wheel = find_wheel()
    remove_unsupported_modules(wheel)
    verify_release_wheel(wheel)
    missing = [path for path in (*DOCUMENTS, *EXAMPLES) if not path.is_file()]
    if missing:
        raise FileNotFoundError(f"release input missing: {missing[0]}")

    bundle_name = f"47dr-driver-sdk-{__version__}"
    archive_path = DIST_DIR / f"{bundle_name}.zip"
    payloads: list[tuple[str, bytes]] = []
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
            "requires_python": ">=3.10",
            "runtime_dependencies": ["numpy>=1.23"],
            "supported_scope": [
                "board discovery and network provisioning",
                "RFDC and output-channel configuration",
                "waveform generation and DDR upload",
                "finite burst scheduling",
                "software and external Trigger playback",
                "master/slave SYNC control",
                "in-memory simulation",
            ],
            "excluded_features": [
                "TDC calibration, compensation, diagnostics, and public API"
            ],
            "generated_utc": datetime.now(timezone.utc).isoformat(),
            "wheel": wheel.name,
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
        f"{sha256(wheel.read_bytes())}  {wheel.name}\n"
        f"{sha256(archive_path.read_bytes())}  {archive_path.name}\n",
        encoding="ascii",
    )
    print(f"SDK bundle: {archive_path}")
    print(f"Checksums:  {external_checksums}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
