#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/vendor"
REPO_DIR="${VENDOR_DIR}/ucb-bar-riscv-mini"
REPO_URL="https://github.com/ucb-bar/riscv-mini.git"
PINNED_COMMIT="3eda724c437c73f3192fcbaaf76ae93b5eb870b0"

mkdir -p "${VENDOR_DIR}"

if [[ ! -d "${REPO_DIR}/.git" ]]; then
  git clone "${REPO_URL}" "${REPO_DIR}"
fi

git -C "${REPO_DIR}" fetch --tags origin
git -C "${REPO_DIR}" checkout "${PINNED_COMMIT}"

echo "riscv-mini checked out at ${PINNED_COMMIT}"
echo "${REPO_DIR}"
