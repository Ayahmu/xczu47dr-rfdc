"""The delivered driver is a set of binary wheels: compiled modules, no sources.

The wheels themselves are built and tested inside the manylinux container
(``make driver-wheel``); these tests cover what goes into that build and the
check that guards what comes out of it.
"""

import io
import json
import sys
import zipfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "software"))

import build_driver_release as release  # noqa: E402
import build_driver_wheels as wheels  # noqa: E402

VERSION = wheels.__version__
SO = "cpython-312-x86_64-linux-gnu.so"


def _wheel(directory: Path, tag: str = "cp312", extra=(), drop=(), metadata="Name: 47dr-driver\n") -> Path:
    """A stand-in wheel with the layout the container produces."""
    names = {f"dr47/{module}.{SO}" for module in (*wheels.compiled_modules(), "_fastsend")}
    names |= {"dr47/__init__.py", "dr47/_version.py", "dr47/examples/simulator_quickstart.py"}
    names = (names | set(extra)) - set(drop)
    path = directory / f"47dr_driver-{VERSION}-{tag}-{tag}-manylinux2014_x86_64.manylinux_2_17_x86_64.{wheels.PLATFORM}.whl"
    with zipfile.ZipFile(path, "w") as archive:
        for name in sorted(names):
            archive.writestr(name, b"")
        archive.writestr(f"47dr_driver-{VERSION}.dist-info/METADATA", metadata)
    return path


# ------------------------------------------------------------ what is built

def test_every_module_but_the_entry_points_is_compiled():
    compiled = wheels.compiled_modules()
    sources = {path.stem for path in (ROOT / "software" / "dr47").glob("*.py")}
    assert set(compiled) == sources - {"__init__", "_version", "tdc"}
    assert {"device", "protocol", "bulk", "transport", "waveforms", "simulator"} <= set(compiled)


def test_staged_tree_holds_the_package_without_research_code_or_tooling_notes(tmp_path):
    wheels.stage(tmp_path)
    package = tmp_path / "dr47"
    assert not (package / "tdc.py").exists()
    assert (package / "_version.py").read_text() == f'__version__ = "{VERSION}"\n'
    assert sorted(path.name for path in (package / "examples").glob("*.py")) == sorted(
        path.name for path in (ROOT / "software" / "dr47" / "examples").glob("*.py"))
    # The C source is built from outside the package, so it cannot be packed with it.
    assert (tmp_path / "csrc" / "_fastsend.c").is_file() and not list(package.glob("*.c"))
    assert (tmp_path / "setup.py").read_text() == (ROOT / "software" / "packaging" / "setup_binary.py").read_text()


def test_staged_pyproject_builds_with_cython_and_drops_repository_links(tmp_path):
    wheels.stage(tmp_path)
    import tomllib
    project = tomllib.loads((tmp_path / "pyproject.toml").read_text())
    assert any(requirement.startswith("Cython") for requirement in project["build-system"]["requires"])
    assert "urls" not in project["project"]
    assert project["tool"]["setuptools"]["package-dir"] == {"dr47": "dr47"}
    assert project["tool"]["setuptools"]["include-package-data"] is False
    assert "package-data" not in project["tool"]["setuptools"]
    assert project["project"]["name"] == "47dr-driver" and project["project"]["scripts"] == {"dr47-network": "dr47.cli:main"}


def test_modules_are_compiled_as_plain_python_without_debug_data():
    setup = (ROOT / "software" / "packaging" / "setup_binary.py").read_text()
    assert '"annotation_typing": False' in setup         # "x: int" stays a hint, numpy integers still pass
    assert '"-g0"' in setup and '"-s"' in setup
    container = (ROOT / "software" / "packaging" / "build_in_container.sh").read_text()
    assert "auditwheel repair --strip" in container
    assert "DR47_TEST_INSTALLED=1" in container           # the driver tests run against each installed wheel


def test_wheel_tests_exist_and_cover_the_driver():
    for name in wheels.WHEEL_TESTS:
        assert (ROOT / "tests" / name).is_file(), name
    assert {"test_wave_bulk_upload.py", "test_waveform_protocol_v2.py", "test_playback.py"} <= set(wheels.WHEEL_TESTS)


# ------------------------------------------------------------ what comes out

def test_a_wheel_of_compiled_modules_is_accepted(tmp_path):
    assert wheels.wheel_problems(_wheel(tmp_path)) == []


@pytest.mark.parametrize("change, expected", [
    (dict(extra={"dr47/device.py"}), "source shipped: dr47/device.py"),
    (dict(extra={"dr47/_fastsend.c"}), "source shipped: dr47/_fastsend.c"),
    (dict(extra={f"dr47/tdc.{SO}"}), "excluded module shipped"),
    (dict(drop={f"dr47/protocol.{SO}"}), "compiled module missing: dr47/protocol"),
    (dict(drop={f"dr47/_fastsend.{SO}"}), "compiled module missing: dr47/_fastsend"),
    (dict(metadata="Project-URL: Repository, https://github.com/someone/repo\n"), "source repository"),
])
def test_a_wheel_that_leaks_or_lacks_something_is_rejected(tmp_path, change, expected):
    problems = wheels.wheel_problems(_wheel(tmp_path, **change))
    assert any(expected in problem for problem in problems), problems


def test_a_pure_python_wheel_is_rejected(tmp_path):
    path = tmp_path / f"47dr_driver-{VERSION}-py3-none-any.whl"
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("dr47/device.py", b"")
    assert any("not a CPython" in problem for problem in wheels.wheel_problems(path))


def test_built_wheels_pass_the_check():
    built = wheels.built_wheels()
    if not built:
        pytest.skip("no wheels in dist/ (make driver-wheel)")
    for wheel in built:
        assert wheels.wheel_problems(wheel) == [], wheel.name


# ------------------------------------------------------------ the SDK bundle

def test_release_needs_a_wheel_for_every_supported_python(tmp_path, monkeypatch):
    monkeypatch.setattr(wheels, "DIST_DIR", tmp_path)
    for tag in wheels.PYTHON_TAGS[:-1]:
        _wheel(tmp_path, tag)
    with pytest.raises(FileNotFoundError, match=wheels.PYTHON_TAGS[-1]):
        release.release_wheels()
    _wheel(tmp_path, wheels.PYTHON_TAGS[-1])
    assert len(release.release_wheels()) == len(wheels.PYTHON_TAGS)


def test_bundle_carries_the_binary_wheels_documents_examples_and_checksums(tmp_path, monkeypatch):
    monkeypatch.setattr(wheels, "DIST_DIR", tmp_path)
    monkeypatch.setattr(release, "DIST_DIR", tmp_path)
    built = [_wheel(tmp_path, tag) for tag in wheels.PYTHON_TAGS]
    (tmp_path / f"47dr_driver-{VERSION}-py3-none-any.whl").write_bytes(b"left over from a source build")
    archive_path = release.build_bundle(release.release_wheels())

    with zipfile.ZipFile(archive_path) as archive:
        names = archive.namelist()
        prefix = f"47dr-driver-sdk-{VERSION}/"
        assert sorted(n for n in names if n.startswith(prefix + "packages/")) == sorted(
            prefix + "packages/" + wheel.name for wheel in built)
        assert not any(name.endswith("py3-none-any.whl") for name in names)
        assert prefix + "examples/simulator_quickstart.py" in names
        assert prefix + "docs/API参考.md" in names
        manifest = json.loads(archive.read(prefix + "MANIFEST.json"))
        assert manifest["wheels"] == [wheel.name for wheel in built]
        assert manifest["python_versions"] == ["3.10", "3.11", "3.12", "3.13", "3.14"]
        assert manifest["driver_version"] == VERSION
        sums = archive.read(prefix + "SHA256SUMS").decode()
        for wheel in built:
            assert f"packages/{wheel.name}" in sums
    listed = (tmp_path / "SHA256SUMS").read_text()
    assert archive_path.name in listed and all(wheel.name in listed for wheel in built)
    assert "py3-none-any" not in listed


def test_makefile_builds_the_release_from_the_binary_wheels():
    makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
    assert "\ndriver-wheel:\n\t$(PYTHON) software/build_driver_wheels.py\n" in makefile
    assert "\ndriver-release: driver-wheel\n\t$(PYTHON) software/build_driver_release.py\n" in makefile
    assert "py3-none-any" not in makefile
