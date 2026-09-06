#!/usr/bin/env bash
# Load a bitstream onto the XCZU47DR and verify what actually ended up in the PL.
#
# Why not "make program" / firmware/scripts/program.tcl:
#   That script does "rst -system" before programming the PL.  On a board that
#   boots from QSPI a system reset re-runs the BootROM, the FSBL reloads a
#   bitstream from QSPI, and it races the JTAG download.  The script prints
#   "Programming complete!" either way, so a failed load is silent.  Programming
#   through hw_manager (no PS reset) and then downloading the ELF with
#   DOWNLOAD_ELF_ONLY=1 is reliable.
#
# Why there is a psu_init step anyway:
#   DOWNLOAD_ELF_ONLY=1 also skips psu_init, and psu_init is what brings up the
#   PS DDR controller.  The application ELF links its sections at 0x0, i.e. in
#   DDR, so on a board where nothing else has run psu_init this cycle the
#   download dies with
#       Memory write error at 0x0. Blocked address 0x0. DDR controller is not initialized
#   A board strapped for JTAG boot (BOOT_MODE_USER at 0xFF5E0200 reads 0) has no
#   FSBL at all, so DDR is uninitialized after every power cycle and after every
#   PS reset - the failure comes back every time.  Step 1 therefore reads the
#   DDRC status register and runs psu_init only when DDR is not already in normal
#   operating mode, still without "rst -system".
#
# Why the verification step matters:
#   custom_xczu47dr_slave and custom_xczu47dr_slave_trigout both have 4 ILAs, 0
#   VIOs and the same probe names, so core counts cannot tell them apart.  The
#   only runtime discriminator is sync_xs20_oe: 1 in a trigout build (XS20 driven
#   as a Trigger output), 0 in the plain slave (XS20 is a SYNC input).
#
# Usage:  ./software/load_and_verify.sh [slave_trigout|slave]
#   SKIP_PSU_INIT=1  never run psu_init, even if DDR looks uninitialized
#   FORCE_PSU_INIT=1 run psu_init unconditionally
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

# ---------------------------------------------------------------- psu_init ----
# DDRC STAT is at 0xFD070004; bits [2:0] are the operating mode.  1 = normal,
# 0 = still in init.  Anything other than normal means the ELF download to 0x0
# would fail, so bring DDR up first.  psu_init is run WITHOUT "rst -system" so
# the BootROM is not re-entered.  It runs before the PL is programmed, because
# psu_init also drives PS-PL isolation and resets - doing it afterwards would
# disturb a bitstream that was just loaded.
echo "== 1/4 checking PS DDR controller =="
if [ "${SKIP_PSU_INIT:-0}" = "1" ]; then
  echo "  SKIP_PSU_INIT=1; not touching the PS"
else
  cat > "$WORK/ddrstat.tcl" <<TCL
connect -url tcp:127.0.0.1:3121
if {[catch {targets -set -filter {name =~ "PSU"}} e]} { puts "===DDRSTAT=no_psu_target==="; exit 0 }
if {[catch {set raw [mrd -force 0xFD070004]} e]} { puts "===DDRSTAT=unreadable==="; exit 0 }
set hex [lindex [split [string trim \$raw]] end]
puts "===DDRSTAT=[expr {("0x\$hex" & 0x7)}] raw=\$hex==="
TCL
  DDRSTAT=$(xsct "$WORK/ddrstat.tcl" 2>/dev/null | sed -n 's/^===DDRSTAT=\([^ =]*\).*$/\1/p' | tail -1)
  echo "  DDRC STAT operating mode = ${DDRSTAT:-unknown}  (1 = normal, 0 = still in init)"
  # A missing PSU target is a different failure from "DDR not up yet": the PS
  # itself is unreachable over JTAG, usually a wedged AXI-AP (DAP status
  # 0x3xxxxxxx) after something read an address that never answers.  psu_init
  # cannot run without that target and no amount of PL programming brings it
  # back, so say what actually clears it instead of failing obscurely.  This
  # script will not issue the reset itself: "rst -srst" also wipes the PL
  # configuration, and on a QSPI-boot board "rst -system" re-enters the BootROM.
  if [ "$DDRSTAT" = "no_psu_target" ] || [ "$DDRSTAT" = "unreadable" ]; then
    echo "  available JTAG targets:" >&2
    printf 'connect -url tcp:127.0.0.1:3121\ntargets\n' > "$WORK/t.tcl"
    xsct "$WORK/t.tcl" 2>/dev/null | sed -n '/^ *[0-9]\+ /p' | sed 's/^/    /' >&2 || true
    fail "PS is not reachable over JTAG (${DDRSTAT}); power-cycle the board, then run
        make program TARGET=custom_xczu47dr_${ROLE}
       once to run psu_init, after which this script can be used for iterations"
  fi
  if [ "${FORCE_PSU_INIT:-0}" = "1" ] || [ "$DDRSTAT" != "1" ]; then
    echo "  running psu_init (no rst -system) to bring up DDR"
    cat > "$WORK/psuinit.tcl" <<TCL
connect -url tcp:127.0.0.1:3121
targets -set -filter {name =~ "PSU"}
source ${PSU}
psu_init
after 500
psu_ps_pl_isolation_removal
psu_ps_pl_reset_config
set raw [mrd -force 0xFD070004]
set hex [lindex [split [string trim \$raw]] end]
puts "===DDRSTAT_AFTER=[expr {("0x\$hex" & 0x7)}]==="
TCL
    xsct "$WORK/psuinit.tcl" > "$WORK/psuinit.log" 2>&1
    AFTER=$(sed -n 's/^===DDRSTAT_AFTER=\([0-9]*\).*$/\1/p' "$WORK/psuinit.log" | tail -1)
    echo "  DDRC STAT after psu_init = ${AFTER:-unknown}"
    if [ "$AFTER" != "1" ]; then
      sed -n '1,80p' "$WORK/psuinit.log" >&2
      fail "psu_init did not bring DDR to normal mode (STAT=${AFTER:-unknown}); the ELF download would fail at 0x0"
    fi
  else
    echo "  DDR already initialized; skipping psu_init"
  fi
fi

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

echo "== 2/4 programming PL (no PS reset) =="
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

echo "== 3/4 downloading ELF (PL preserved) =="
ELF_LOG="$WORK/elf-download.log"
set +e
( cd "$REPO/firmware" && JTAG_CABLE_SERIAL="$CABLE" DOWNLOAD_ELF_ONLY=1 \
    xsct scripts/program.tcl "$BIT" "$ELF" "$PSU" >"$ELF_LOG" 2>&1 )
ELF_STATUS=$?
grep -E "preserving|Starting|complete|ERROR|WARNING|failed|Failed" "$ELF_LOG" || true
if [ "$ELF_STATUS" -ne 0 ]; then
  echo "XSCT exited with status $ELF_STATUS; full diagnostic follows:" >&2
  sed -n '1,240p' "$ELF_LOG" >&2
  fail "ELF download failed (XSCT status $ELF_STATUS)"
fi

echo "== 4/4 discovering board IP (changes with the bitstream) =="
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
