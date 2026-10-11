#!/bin/bash
# Runs inside the manylinux image: builds one wheel per Python version from the
# staged tree in /src, retags them with auditwheel and tries each one out.
#   PYTHON_TAGS   interpreters to build for, e.g. "cp310 cp311"
#   DRIVER_TESTS  test files (paths under /repo) to run against each installed wheel
#   /src          staged source tree (read-only)
#   /out          finished wheels
#   /repo         the repository (read-only), for the tests
set -euo pipefail

export HOME=/tmp/home PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_WARN_SCRIPT_LOCATION=1
mkdir -p "${HOME}" /tmp/raw

for tag in ${PYTHON_TAGS}; do
    python="/opt/python/${tag}-${tag}/bin/python"
    work="$(mktemp -d)"
    cp -r /src/. "${work}"
    echo "=== ${tag}: build"
    (cd "${work}" && "${python}" -m pip wheel --quiet --no-deps -w /tmp/raw .)
done

for wheel in /tmp/raw/*.whl; do
    auditwheel repair --strip --plat "${AUDITWHEEL_PLAT}" -w /out "${wheel}" > /tmp/auditwheel.log 2>&1 \
        || { cat /tmp/auditwheel.log; exit 1; }
done

for tag in ${PYTHON_TAGS}; do
    python="/opt/python/${tag}-${tag}/bin/python"
    echo "=== ${tag}: install and run the simulator example"
    venv="$(mktemp -d)/venv"
    "${python}" -m venv "${venv}"
    "${venv}/bin/pip" install --quiet /out/*-"${tag}"-"${tag}"-*.whl
    # From an empty directory, isolated: only the installed wheel can be imported.
    (cd "$(mktemp -d)" && "${venv}/bin/python" -I -c '
import dr47, dr47.bulk, runpy
assert dr47.device.__file__.endswith(".so"), dr47.device.__file__
assert dr47.bulk.load_fastsend() is not None, "the shipped sender core did not load"
runpy.run_module("dr47.examples.simulator_quickstart", run_name="__main__")
print("ok", dr47.__version__, dr47.device.__file__.rsplit("/", 1)[1])
')
    if [ -n "${DRIVER_TESTS:-}" ]; then
        echo "=== ${tag}: driver tests against the installed wheel"
        "${venv}/bin/pip" install --quiet pytest
        (cd "$(mktemp -d)" && DR47_TEST_INSTALLED=1 "${venv}/bin/python" -m pytest -p no:cacheprovider -q ${DRIVER_TESTS})
    fi
done
