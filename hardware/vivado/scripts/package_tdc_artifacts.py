"""Package a verified TDC bitstream with its exact source and test provenance."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import struct
import subprocess
import zipfile
from datetime import datetime, timezone
from pathlib import Path


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def bit_header(path: Path) -> dict:
    with path.open("rb") as stream:
        def number(size):
            value = stream.read(size)
            if len(value) != size:
                raise ValueError("Truncated bitstream header")
            return int.from_bytes(value, "big")
        magic = stream.read(number(2))
        if magic != bytes.fromhex("0ff00ff00ff00ff000") or number(2) != 1:
            raise ValueError("Invalid Xilinx bitstream header")
        result = {}
        names = {b"a": "design", b"b": "part", b"c": "date", b"d": "time"}
        tag = stream.read(1)
        for expected in (b"a", b"b", b"c", b"d"):
            if tag != expected:
                raise ValueError("Unexpected bitstream header field")
            result[names[tag]] = stream.read(number(2)).rstrip(b"\0").decode("ascii")
            tag = stream.read(1)
        if tag != b"e":
            raise ValueError("Missing bitstream configuration payload")
        result["configuration_bytes"] = number(4)
        if path.stat().st_size - stream.tell() != result["configuration_bytes"]:
            raise ValueError("Bitstream payload length mismatch")
    if "xczu47dr" not in result["part"]:
        raise ValueError("Bitstream targets a different FPGA")
    return result


def main():
    root = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=root / "artifacts/tdc_20260907")
    parser.add_argument("--work", type=Path, default=root / "work/tdc_20260907")
    args = parser.parse_args()
    output = args.output.resolve()
    verified = json.loads((output / "verification.json").read_text())
    if (verified.get("schema") != 2 or verified.get("target") != "custom_xczu47dr_slave"
            or not verified.get("all_timing_constraints_met")
            or not verified.get("setup_hold_passed")
            or not verified.get("clock_coverage_passed")
            or not verified.get("bus_skew_passed")
            or verified.get("bus_skew_constraint_count", 0) < 1
            or verified.get("bus_skew_result_count", 0) < verified["bus_skew_constraint_count"]
            or verified.get("blocking_drc_count") != 0):
        raise ValueError("Implementation has not passed final validation")
    bit = output / "custom_xczu47dr_slave.bit"
    ltx = output / "custom_xczu47dr_slave.ltx"
    if not ltx.is_file() or not ltx.stat().st_size:
        raise ValueError("Matching ILA probes are missing")
    if digest(bit) != verified.get("bit_sha256") or digest(ltx) != verified.get("ltx_sha256"):
        raise ValueError("Bitstream or ILA probes differ from the verified export")
    test_log = args.work / "regression_verified.log"
    test_text = test_log.read_text(errors="replace")
    count = re.search(r"^Ran (\d+) tests in ([0-9.]+)s$", test_text, re.MULTILINE)
    passed = re.search(r"^OK(?: \(skipped=(\d+)\))?$", test_text, re.MULTILINE)
    if not count or not passed:
        raise ValueError("Complete regression success is not recorded")
    # TDC is outside the current SDK.  Keep this historical packager usable by
    # taking provenance files from the archived artifact when the old source
    # document or work image is not present in a cleaned checkout.
    review_source = root / "docs/TDC_项目评估与实施记录.md"
    if not review_source.is_file():
        review_source = root / "artifacts/tdc_20260907/TDC_PROJECT_REVIEW.md"
    review_target = output / "TDC_PROJECT_REVIEW.md"
    if review_source.resolve() != review_target.resolve():
        shutil.copy2(review_source, review_target)
    model_source = args.work / "tdc_model_limits.png"
    if not model_source.is_file():
        model_source = root / "artifacts/tdc_20260907/tdc_model_limits.png"
    model_target = output / "tdc_model_limits.png"
    if model_source.resolve() != model_target.resolve():
        shutil.copy2(model_source, model_target)
    shutil.copy2(test_log, output / "regression.log")
    source_files = set()
    for directory, suffixes in (
        (root / "hardware/vivado/src", {".v", ".sv", ".vhd"}),
        (root / "hardware/vivado/constraints", {".xdc"}),
        (root / "hardware/vivado/xdc", {".xdc"}),
        (root / "hardware/vivado/scripts", {".tcl", ".py"}),
        (root / "hardware/chisel/generated", {".v", ".tcl"}),
    ):
        source_files.update(path for path in directory.rglob("*") if path.is_file() and path.suffix in suffixes)
    sources = {path.relative_to(root).as_posix(): digest(path) for path in sorted(source_files)}
    extensions = {".bit", ".ltx", ".rpt", ".md", ".png", ".log"}
    files = sorted(path for path in output.iterdir()
                   if path.is_file() and (path.suffix in extensions or path.name == "verification.json"))
    artifacts = {path.name: {"sha256": digest(path), "bytes": path.stat().st_size} for path in files}
    manifest = {
        **verified, "created_utc": datetime.now(timezone.utc).isoformat(),
        "git_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "working_tree_modified": True, "bit_header": bit_header(bit),
        "tests": {"run": int(count[1]), "seconds": float(count[2]), "skipped": int(passed[1] or 0)},
        "source_sha256": sources, "artifacts": artifacts,
        "calibration_required": True,
        "analog_jitter_verified": False,
    }
    manifest_file = output / "build_manifest.json"
    manifest_file.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    files.append(manifest_file)
    checksums = output / "SHA256SUMS"
    checksums.write_text("".join(f"{digest(path)}  {path.name}\n" for path in files), encoding="utf-8")
    archive = output / "TDC_20260907_slave.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as package:
        for path in [*files, checksums]:
            package.write(path, path.name)
    print(json.dumps({"bit": str(bit), "sha256": digest(bit), "package": str(archive),
                      "tests": manifest["tests"], "wns_ns": verified["wns_ns"], "whs_ns": verified["whs_ns"]}, indent=2))


if __name__ == "__main__":
    main()
