#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHISEL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
GENERATED_DIR="${CHISEL_DIR}/generated"

"${CHISEL_DIR}/build.sh" glue >/tmp/verify_glue_verilog.log

grep -q "module ChiselConstLow" "${GENERATED_DIR}/ChiselConstLow.v"
grep -q "assign io_dout = 1'h0" "${GENERATED_DIR}/ChiselConstLow.v"
grep -q "module ChiselConstHigh" "${GENERATED_DIR}/ChiselConstHigh.v"
grep -q "assign io_dout = 1'h1" "${GENERATED_DIR}/ChiselConstHigh.v"
grep -q "module ChiselInvert1" "${GENERATED_DIR}/ChiselInvert1.v"
grep -q "assign io_Res = ~io_Op1" "${GENERATED_DIR}/ChiselInvert1.v"

printf 'Glue Verilog verification passed\n'
