#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="${ROOT_DIR}/vendor/ucb-bar-riscv-mini"
GENERATED_DIR="${ROOT_DIR}/generated"

if [[ ! -d "${REPO_DIR}/.git" ]]; then
  "${SCRIPT_DIR}/fetch_riscv_mini.sh"
fi

make -C "${REPO_DIR}" compile

mkdir -p "${GENERATED_DIR}"
cp "${REPO_DIR}/generated-src/Tile.sv" "${GENERATED_DIR}/Tile.sv"

echo "generated ${GENERATED_DIR}/Tile.sv"
