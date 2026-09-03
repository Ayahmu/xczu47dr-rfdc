#!/usr/bin/env bash
# Load a bitstream onto the XCZU47DR and verify what actually ended up in the PL.
#
# Why not "make program" / firmware/scripts/program.tcl:
#   That script does "rst -system" before programming the PL.  On this board a
#   system reset re-runs the BootROM, the FSBL reloads a bitstream from QSPI, and
#   it races the JTAG download.  The script prints "Programming complete!" either
#   way, so a failed load is silent.  Programming through hw_manager (no PS
#   reset) and then downloading the ELF with DOWNLOAD_ELF_ONLY=1 is reliable.
#
# Why the verification step matters:
#   custom_xczu47dr_slave and custom_xczu47dr_slave_trigout both have 4 ILAs, 0
#   VIOs and the same probe names, so core counts cannot tell them apart.  The
#   only runtime discriminator is sync_xs20_oe: 1 in a trigout build (XS20 driven
#   as a Trigger output), 0 in the plain slave (XS20 is a SYNC input).
#
# Usage:  ./software/load_and_verify.sh [slave_trigout|slave]
set -uo pipefail

ROLE=${1:-slave_trigout}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CABLE=${JTAG_CABLE_SERIAL:-210512180082}
BIT="$REPO/artifacts/custom_xczu47dr_${ROLE}.bit"
LTX="$REPO/artifacts/custom_xczu47dr_${ROLE}.ltx"
# The PS side is identical for both slave variants, so both reuse the slave ELF.
ELF="$REPO/artifacts/custom_xczu47dr_slave.elf"
PSU="$REPO/artifacts/custom_xczu47dr_slave_psu_init.tcl"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAILED: $*" >&2; exit 1; }

for f in "$BIT" "$LTX" "$ELF" "$PSU"; do
  [ -s "$f" ] || fail "missing artifact: $f"
done
echo "role   : $ROLE"
echo "bit    : $(sha256sum "$BIT" | cut -c1-16)  $(wc -c <"$BIT") bytes"

cat > "$WORK/prog.tcl" <<TCL
open_hw_manager
connect_hw_server -allow_non_jtag -url localhost:3121
open_hw_target {localhost:3121/xilinx_tcf/Xilinx/${CABLE}}
set dev [lindex [get_hw_devices] 0]
current_hw_device \$dev
set_property PROGRAM.FILE {${BIT}} \$dev
set_property PROBES.FILE {${LTX}} \$dev
set_property FULL_PROBES.FILE {${LTX}} \$dev
program_hw_devices \$dev
after 4000
refresh_hw_device \$dev
after 2000
set ila {}
foreach c [get_hw_ilas -quiet -of_objects \$dev] {
  if {[llength [get_hw_probes -quiet *sync_xs20_oe* -of_objects \$c]] > 0} { set ila \$c; break }
}
if {\$ila eq ""} { puts "===VERIFY oe=absent ila=[llength [get_hw_ilas -quiet -of_objects \$dev]]==="; close_hw_manager; exit 0 }
current_hw_ila \$ila
run_hw_ila -trigger_now \$ila
wait_on_hw_ila \$ila
write_hw_ila_data -force -csv_file ${WORK}/v.csv [upload_hw_ila_data \$ila]
puts "===ILA_COUNT=[llength [get_hw_ilas -quiet -of_objects \$dev]]==="
puts "===LATPROBE=[llength [get_hw_probes -quiet *trig_lat_delta_max* -of_objects [get_hw_ilas -quiet -of_objects \$dev]]]==="
close_hw_manager
TCL

echo "== 1/3 programming PL (no PS reset) =="
vivado -mode batch -notrace -source "$WORK/prog.tcl" 2>&1 | grep -E "^===|^ERROR" || true

python3 - "$WORK/v.csv" <<'PY'
import csv, sys, pathlib
p = pathlib.Path(sys.argv[1])
if not p.exists():
    print("  (no ILA capture - cannot check sync_xs20_oe)"); raise SystemExit
rows = [r for r in csv.DictReader(p.open()) if (r.get('Sample in Buffer') or '').strip().isdigit()]
col = next((c for c in rows[0] if 'sync_xs20_oe' in c), None)
vals = sorted({r[col].strip() for r in rows}) if col else []
print(f"  sync_xs20_oe = {vals}   (1 = trigout / XS20 drives Trigger, 0 = plain slave)")
PY

echo "== 2/3 downloading ELF (PL preserved) =="
( cd "$REPO/firmware" && JTAG_CABLE_SERIAL="$CABLE" DOWNLOAD_ELF_ONLY=1 \
    xsct scripts/program.tcl "$BIT" "$ELF" "$PSU" 2>&1 \
    | grep -E "preserving|Starting|complete|ERROR" ) || fail "ELF download failed"

echo "== 3/3 discovering board IP (changes with the bitstream) =="
sleep 10
PYTHONPATH="$REPO/software" python3 - <<'PY'
from dr47.network import discover_boards
bs = discover_boards(interface="enp1s0f0", source_ip="169.254.250.11",
                     source_cidr="169.254.250.11/16",
                     broadcast_ip="169.254.255.255", port=1234)
if not bs:
    print("  no board answered the broadcast")
for b in bs:
    print(f"  RFSOC_BOARD_IP={b.current_ip}   MAC={b.current_mac}  UID={b.device_uid}")
PY
