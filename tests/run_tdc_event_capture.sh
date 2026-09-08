#!/usr/bin/env bash
set -eo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
sim_dir=${1:-"$repo/work/tdc_20260907/event_capture_sim"}
mkdir -p "$sim_dir"
cd "$sim_dir"
source /tools/Xilinx/Vivado/2024.2/settings64.sh
set -u
xvlog --sv "$repo/tests/tdc_capture_primitives_sim.v" \
  "$repo/hardware/vivado/src/tdc_event_capture.v" "$repo/tests/tb_tdc_event_capture.sv"
xelab tb_tdc_event_capture -s tdc_event_capture_sim
xsim tdc_event_capture_sim -R | tee result.log
if ! grep -q '^PASS:' result.log || grep -Eq '^(Fatal:|Error:|ERROR:)' result.log; then
  exit 1
fi
