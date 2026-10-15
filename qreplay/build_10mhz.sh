#!/bin/bash
# QReplay bench image: 10 MHz-reference hardware + firmware into
# artifacts/10mhz/ (about 70 min).  Run detached, e.g.
#   setsid bash qreplay/build_10mhz.sh > build_10mhz.log 2>&1 &
set -e
cd "$(dirname "$0")/.."
source /tools/Xilinx/Vivado/2024.2/settings64.sh
source /tools/Xilinx/Vitis/2024.2/settings64.sh
date
make hardware-10mhz
make firmware ARTIFACT_DIR="$PWD/artifacts/10mhz"
echo "EXIT all=done $(date)"
