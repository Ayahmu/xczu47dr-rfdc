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
# Usage:  ./software/load_and_verify.sh [slave|master]
#   SKIP_PSU_INIT=1  never run psu_init, even if DDR looks uninitialized
#   FORCE_PSU_INIT=1 run psu_init unconditionally
set -uo pipefail

ROLE=${1:-slave}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CABLE=${JTAG_CABLE_SERIAL:-210512180082}
XSA="$REPO/artifacts/custom_xczu47dr_${ROLE}.xsa"
ELF="$REPO/artifacts/custom_xczu47dr_${ROLE}.elf"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PSU="$WORK/psu_init.tcl"
BIT="$WORK/${ROLE}.bit"
MANIFEST="$WORK/build_manifest.json"
PYTHON_BIN="${PYTHON:-$REPO/.venv/bin/python}"
if [ ! -x "$PYTHON_BIN" ]; then
  PYTHON_BIN=python3
fi

fail() { echo "FAILED: $*" >&2; exit 1; }

case "$ROLE" in
  slave|master) ;;
  *) fail "unsupported role '$ROLE' (use slave or master)" ;;
esac

for f in "$XSA" "$ELF"; do
  [ -s "$f" ] || fail "missing artifact: $f"
done
member=$(unzip -Z1 "$XSA" | awk '/\.tmp\.bit$/ {print; n++} END {if (n != 1) exit 1}') || fail "XSA must contain exactly one embedded .tmp.bit"
unzip -p "$XSA" "$member" > "$BIT" || fail "cannot extract embedded bitstream"
unzip -p "$XSA" psu_init.tcl > "$PSU" || fail "XSA does not contain psu_init.tcl"
unzip -p "$XSA" build_manifest.json > "$MANIFEST" || fail "XSA does not contain build_manifest.json; rebuild the production XSA"
EXPECTED_SOURCE_COMMIT=$(
  "$PYTHON_BIN" - "$MANIFEST" "$ROLE" <<'PY'
import json
import sys

manifest_path, role = sys.argv[1:]
try:
    with open(manifest_path, encoding="utf-8") as stream:
        manifest = json.load(stream)
except (OSError, ValueError) as exc:
    print(f"invalid XSA build manifest: {exc}", file=sys.stderr)
    raise SystemExit(1)
expected_target = f"custom_xczu47dr_{role}"
checks = {
    "target": manifest.get("target") == expected_target,
    "protocol_version": int(manifest.get("protocol_version", 0)) == 3,
    "trigger_path_version": int(manifest.get("trigger_path_version", 0)) == 3,
    "build_profile_id": int(manifest.get("build_profile_id", 0)) == 1,
    "ila_enabled": not bool(manifest.get("ila_enabled", True)),
}
if not all(checks.values()):
    bad = ", ".join(name for name, ok in checks.items() if not ok)
    print(f"incompatible XSA build manifest ({bad})", file=sys.stderr)
    raise SystemExit(1)
source = str(manifest.get("source_commit", "")).lower()
if len(source) != 8 or any(ch not in "0123456789abcdef" for ch in source):
    print("build manifest has no valid source_commit", file=sys.stderr)
    raise SystemExit(1)
print(source)
PY
) || fail "XSA build identity validation failed"
echo "role   : $ROLE"
echo "bit    : $(sha256sum "$BIT" | cut -c1-16)  $(wc -c <"$BIT") bytes"
echo "source : $EXPECTED_SOURCE_COMMIT  trigger_path=3"

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
set devs [get_hw_devices -quiet -filter {NAME =~ "*xczu47dr*"}]
if {[llength \$devs] == 0} { set devs [get_hw_devices -quiet] }
set dev [lindex \$devs 0]
if {\$dev eq ""} { puts "===ERROR no FPGA device found==="; close_hw_manager; exit 1 }
current_hw_device \$dev
set_property PROGRAM.FILE {${BIT}} \$dev
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
set +e
vivado -mode batch -notrace -source "$WORK/prog.tcl" >"$WORK/pl-program.log" 2>&1
PL_STATUS=$?
set -e
grep -E "^===|^ERROR|ERROR:" "$WORK/pl-program.log" || true
if [ "$PL_STATUS" -ne 0 ]; then
  echo "Vivado exited with status $PL_STATUS; full diagnostic follows:" >&2
  sed -n '1,240p' "$WORK/pl-program.log" >&2
  fail "PL programming failed"
fi

"$PYTHON_BIN" - "$WORK/v.csv" <<'PY'
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
DISCOVERY_INTERFACE="${DISCOVERY_INTERFACE:-enp1s0f0}"
DISCOVERY_SOURCE_IP="${DISCOVERY_SOURCE_IP:-169.254.250.11}"
DISCOVERY_SOURCE_CIDR="${DISCOVERY_SOURCE_CIDR:-169.254.250.11/16}"
DISCOVERY_BROADCAST_IP="${DISCOVERY_BROADCAST_IP:-169.254.255.255}"
PYTHONPATH="$REPO/software" "$PYTHON_BIN" - "$ROLE" "$EXPECTED_SOURCE_COMMIT" \
    "$DISCOVERY_INTERFACE" "$DISCOVERY_SOURCE_IP" "$DISCOVERY_SOURCE_CIDR" "$DISCOVERY_BROADCAST_IP" <<'PY'
import sys

from dr47.network import discover_boards
from dr47.device import Dr47Device

role, source_hex, interface, source_ip, source_cidr, broadcast_ip = sys.argv[1:]
expected_source = int(source_hex, 16)
bs = discover_boards(interface=interface, source_ip=source_ip,
                     source_cidr=source_cidr, broadcast_ip=broadcast_ip,
                     port=1234)
if not bs:
    raise SystemExit("no board answered the broadcast")
verified = False
for b in bs:
    print(f"  RFSOC_BOARD_IP={b.current_ip}   MAC={b.current_mac}  UID={b.device_uid}")
    device = Dr47Device(
        b.current_ip, 1234, timeout_s=3, udp_interface=interface,
        udp_source_ip=source_ip, expected_build_profile_id=1,
        expected_trigger_path_version=3,
        expected_source_commit_id=expected_source,
        sync_role=role,
    )
    try:
        device.connect()
        caps = device.capabilities
        print(f"  HELLO source=0x{caps.source_commit_id:08x} trigger_path={caps.trigger_path_version} role={caps.sync_role}")
        if caps.sync_role != role:
            continue
        verified = True
    except Exception as exc:
        print(f"  identity check failed for {b.current_ip}: {exc}", file=sys.stderr)
    finally:
        device.close()
if not verified:
    raise SystemExit("no discovered board matched the XSA build identity and role")
PY
