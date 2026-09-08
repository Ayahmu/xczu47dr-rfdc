#!/usr/bin/env python3
"""Report observed TDC build files and verify published artifact checksums."""
import argparse
import hashlib
import json
import re
from pathlib import Path


def main():
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=root / "work/tdc_20260907")
    parser.add_argument("--artifact-dir", type=Path, default=root / "artifacts/tdc_20260907")
    args = parser.parse_args()
    report = {"logs": {}, "artifacts": {}, "verified_publication": False}
    for name in ("synth_final.log", "implementation.log", "export.log", "regression_verified.log", "tdc_integration.log"):
        path = args.build_dir / name
        if path.exists():
            text = path.read_text(errors="replace")
            report["logs"][name] = {
                "modified": path.stat().st_mtime,
                "errors": re.findall(r"^(?:ERROR:|Fatal:|FAILED).*", text, re.MULTILINE),
                "completion_markers": re.findall(r"^(?:TDC_.*(?:COMPLETE|EXPORTED|PASS).*|OK(?: .*)?)$", text, re.MULTILINE),
                "last_lines": text.splitlines()[-3:],
            }
    manifest_path = args.artifact_dir / "build_manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    expected = manifest.get("artifacts", {})
    for name, metadata in expected.items():
        path = args.artifact_dir / name
        if path.is_file():
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            report["artifacts"][name] = {"bytes": path.stat().st_size, "sha256": digest,
                                         "matches_manifest": digest == metadata["sha256"]}
        else:
            report["artifacts"][name] = {"missing": True, "matches_manifest": False}
    report["verified_publication"] = bool(expected) and all(
        item["matches_manifest"] for item in report["artifacts"].values()
    ) and manifest.get("setup_hold_passed") is True
    report["analog_jitter_verified"] = manifest.get("analog_jitter_verified", False)
    sources = manifest.get("source_sha256", {})
    changed = []
    for name, expected_digest in sources.items():
        path = (root / name).resolve()
        if not path.is_relative_to(root.resolve()) or not path.is_file():
            changed.append(name)
        elif hashlib.sha256(path.read_bytes()).hexdigest() != expected_digest:
            changed.append(name)
    report["source_changes_since_publication"] = changed
    report["matches_current_sources"] = bool(sources) and not changed
    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
