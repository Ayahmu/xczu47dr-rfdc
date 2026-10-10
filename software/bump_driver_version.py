#!/usr/bin/env python3
"""Show or change the 47dr-driver version (the single source is software/dr47/_version.py).

    python software/bump_driver_version.py --show
    python software/bump_driver_version.py --part patch|minor|major
    python software/bump_driver_version.py 0.3.0            # explicit version (PEP 440 release)
    python software/bump_driver_version.py 0.3.0 --reinstall
    python software/bump_driver_version.py --sync           # refresh the installed metadata only

An editable install records the version when it is installed, so ``pip list`` keeps showing the
old number until the package is reinstalled; ``--reinstall`` / ``--sync`` do that with the
documented ``pip install -e software/dr47`` (offline: no build isolation, no dependencies).
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

DR47_DIR = Path(__file__).resolve().parent / "dr47"
VERSION_FILE = DR47_DIR / "_version.py"
DISTRIBUTION = "47dr-driver"

_RELEASE = r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
_VERSION = re.compile(rf"^{_RELEASE}((a|b|rc)\d+)?(\.post\d+)?(\.dev\d+)?$")
_ASSIGNMENT = re.compile(r'^(__version__\s*=\s*")([^"]+)(")', re.M)


def validate_version(text: str) -> str:
    """Return ``text`` if it is a PEP 440 release such as 1.2.3, 1.2.3rc1 or 1.2.3.post1."""
    if not isinstance(text, str) or not _VERSION.match(text):
        raise ValueError(f"invalid version {text!r}: use X.Y.Z, optionally with aN/bN/rcN, .postN or .devN")
    return text


def next_version(current: str, *, part: str) -> str:
    match = re.match(rf"^{_RELEASE}$", current)
    if not match:
        raise ValueError(f"current version {current!r} has a suffix; pass an explicit version instead of --part")
    major, minor, patch = (int(group) for group in match.groups())
    if part == "major":
        return f"{major + 1}.0.0"
    if part == "minor":
        return f"{major}.{minor + 1}.0"
    if part == "patch":
        return f"{major}.{minor}.{patch + 1}"
    raise ValueError(f"unknown part {part!r}: use major, minor or patch")


def read_version(path: Path = VERSION_FILE) -> str:
    match = _ASSIGNMENT.search(path.read_text(encoding="utf-8"))
    if not match:
        raise ValueError(f"no __version__ assignment found in {path}")
    return match.group(2)


def set_version(path: Path, new: str) -> tuple[str, str]:
    """Rewrite ``__version__`` in ``path``; return (old, new).  An unchanged version is an error."""
    validate_version(new)
    text = path.read_text(encoding="utf-8")
    old = read_version(path)
    if old == new:
        raise ValueError(f"version is already {old}")
    path.write_text(_ASSIGNMENT.sub(lambda m: f"{m.group(1)}{new}{m.group(3)}", text, count=1), encoding="utf-8")
    return old, new


def installed_version() -> str | None:
    from importlib import metadata
    try:
        return metadata.version(DISTRIBUTION)
    except metadata.PackageNotFoundError:
        return None


def reinstall() -> None:
    subprocess.run(
        [sys.executable, "-m", "pip", "install", "-e", str(DR47_DIR), "--no-build-isolation", "--no-deps", "-q"],
        check=True,
    )


def report(path: Path) -> None:
    source = read_version(path)
    installed = installed_version()
    print(f"source ({path.name}): {source}")
    if path != VERSION_FILE:
        return
    if installed is None:
        print(f"installed {DISTRIBUTION}: not installed")
    elif installed != source:
        print(f"installed {DISTRIBUTION}: {installed}  (stale; run with --sync to refresh)")
    else:
        print(f"installed {DISTRIBUTION}: {installed}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("version", nargs="?", help="new version, e.g. 0.3.0 or 0.3.0rc1")
    parser.add_argument("--part", choices=("major", "minor", "patch"), help="increment one part of X.Y.Z")
    parser.add_argument("--show", action="store_true", help="print the source and installed versions")
    parser.add_argument("--reinstall", action="store_true", help="after changing, refresh the editable install")
    parser.add_argument("--sync", action="store_true", help="only refresh the editable install's metadata")
    parser.add_argument("--file", type=Path, default=VERSION_FILE, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        if args.show or args.sync and not (args.version or args.part):
            if args.sync:
                reinstall()
            report(args.file)
            return 0
        if bool(args.version) == bool(args.part):
            parser.error("give exactly one of: an explicit version, or --part")
        new = args.version if args.version else next_version(read_version(args.file), part=args.part)
        old, new = set_version(args.file, new)
        print(f"{DISTRIBUTION}: {old} -> {new}")
        if args.reinstall or args.sync:
            reinstall()
        report(args.file)
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
