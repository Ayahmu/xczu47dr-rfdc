#!/usr/bin/env bash
set -eo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
source /tools/Xilinx/Vivado/2024.2/settings64.sh
set -u
for test_name in tdc_register_service tdc_compensating_trigger; do
    sim_dir="$repo/work/tdc_20260907/$test_name"
    mkdir -p "$sim_dir"
    cd "$sim_dir"
    xvlog --sv "$repo/hardware/vivado/src/$test_name.v" "$repo/tests/tb_$test_name.sv"
    xelab "tb_$test_name" -s "$test_name"
    xsim "$test_name" -R | tee result.log
    if ! grep -q '^PASS:' result.log || grep -Eq '^(Fatal:|Error:|ERROR:)' result.log; then
        exit 1
    fi
done
