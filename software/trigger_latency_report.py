#!/usr/bin/env python3
"""Read the DAC-domain trigger latency probe over JTAG and summarise it.

Run this after driving external Triggers into XS19.  It takes an immediate ILA
snapshot (no trigger condition) and reports the accumulated registers from
dac_trigger_latency_probe, which live in dac_axis_clk:

  trig_lat_delta_min/max  - DAC cycles the hmc_pl_clk detour adds to the same
                            XS19 edge.  max-min is the launch jitter that path
                            was contributing before the direct capture existed.
  trig_lat_pair_count     - external Triggers seen by both paths
  trig_lat_orphan_count   - events one path saw and the other did not
  dac_direct_input/accept - edges seen / consumed by the direct capture

One DAC cycle is 20 ns (6.4 GS/s / 16x interpolation / 8 samples per beat), so
the probe cannot resolve the 5/12 ns fine structure - the scope does that.  What
it settles is whether the hmc_pl_clk hop adds a *variable* number of DAC cycles.
"""

from __future__ import annotations

import argparse
import csv
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPORT_DIR = ROOT / "trigger_latency_reports"

DAC_AXIS_PERIOD_NS = 20.0
HMC_PL_CLK_PERIOD_NS = 10.416667

# Signals to pull out of the capture, in report order.
PROBE_FIELDS = (
    "trig_lat_delta_last",
    "trig_lat_delta_min",
    "trig_lat_delta_max",
    "trig_lat_start_delta",
    "trig_lat_pair_count",
    "trig_lat_orphan_count",
    "dac_direct_input_count",
    "dac_direct_accept_count",
    "trig_lat_tick",
)
# Probe used to locate the right ILA among several on the device.
ANCHOR_PROBE = "trig_lat_delta_max"


def write_tcl(tcl_path: Path, csv_path: Path, ltx: Path, jtag_target: str) -> None:
    lines = [
        "set_param messaging.defaultLimit 10000",
        "open_hw_manager",
        "connect_hw_server -allow_non_jtag -url localhost:3121",
        f"open_hw_target {{{jtag_target}}}",
        "set dev [lindex [get_hw_devices] 0]",
        "current_hw_device $dev",
        f"set_property PROBES.FILE {{{ltx}}} $dev",
        f"set_property FULL_PROBES.FILE {{{ltx}}} $dev",
        "refresh_hw_device $dev",
        "set ila {}",
        "foreach candidate [get_hw_ilas -of_objects $dev] {",
        f"  if {{[llength [get_hw_probes -quiet *{ANCHOR_PROBE}* -of_objects $candidate]] > 0}} {{",
        "    set ila $candidate; break",
        "  }",
        "}",
        'if {$ila eq ""} { error "trigger latency probe not found - is the new bitstream loaded?" }',
        'puts "Using ILA: [get_property NAME $ila]"',
        "current_hw_ila $ila",
        # Immediate snapshot: the probe registers accumulate, so any sample works.
        "run_hw_ila -trigger_now $ila",
        "wait_on_hw_ila $ila",
        "set data [upload_hw_ila_data $ila]",
        f"write_hw_ila_data -force -csv_file {{{csv_path}}} $data",
        "close_hw_manager",
    ]
    tcl_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _column_for(header: list[str], field: str) -> str | None:
    for name in header:
        if field in name:
            return name
    return None


def parse_csv(csv_path: Path) -> dict[str, int]:
    with csv_path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        header = list(reader.fieldnames or [])
        rows = [r for r in reader if (r.get("Sample in Buffer") or "").strip().isdigit()]
    if not rows:
        raise RuntimeError(f"ILA CSV has no samples: {csv_path}")
    # The accumulating registers only move on a Trigger, so the last sample in
    # the buffer carries the most recent totals.
    last = rows[-1]
    values: dict[str, int] = {}
    for field in PROBE_FIELDS:
        column = _column_for(header, field)
        if column is None:
            continue
        raw = (last.get(column) or "").strip().strip('"').replace("_", "")
        if not raw:
            continue
        try:
            values[field] = int(raw, 16)
        except ValueError:
            continue
    return values


def report(values: dict[str, int]) -> int:
    if not values:
        print("ERROR: none of the latency probes were present in the capture")
        return 1

    missing = [f for f in PROBE_FIELDS if f not in values]
    if missing:
        print(f"WARNING: probes absent from the LTX: {', '.join(missing)}")

    inputs = values.get("dac_direct_input_count")
    accepts = values.get("dac_direct_accept_count")
    pairs = values.get("trig_lat_pair_count", 0)
    orphans = values.get("trig_lat_orphan_count", 0)

    print("--- direct DAC-domain capture (the new launch path) ---")
    if inputs is not None and accepts is not None:
        print(f"  XS19 edges seen     : {inputs}")
        print(f"  Triggers accepted   : {accepts}")
        print(f"  rejected (not ready): {inputs - accepts}")

    print("--- hmc_pl_clk detour, measured against the same edges ---")
    print(f"  paired events       : {pairs}")
    print(f"  orphan events       : {orphans}")

    dmin = values.get("trig_lat_delta_min")
    dmax = values.get("trig_lat_delta_max")
    if pairs == 0 or dmin is None or dmax is None:
        print("  no paired measurements yet - drive some external Triggers first")
        return 0
    if dmin == 0xFFFF:
        print("  delta_min still at its reset seed; no pair completed")
        return 0

    spread = dmax - dmin
    print(f"  delta_min           : {dmin} DAC cycles ({dmin * DAC_AXIS_PERIOD_NS:.1f} ns)")
    print(f"  delta_max           : {dmax} DAC cycles ({dmax * DAC_AXIS_PERIOD_NS:.1f} ns)")
    print(f"  delta_last          : {values.get('trig_lat_delta_last')} DAC cycles")
    print(f"  >>> spread          : {spread} DAC cycles "
          f"({spread * DAC_AXIS_PERIOD_NS:.1f} ns peak-to-peak)")

    print("--- interpretation ---")
    if spread == 0:
        print("  The hmc_pl_clk hop added a CONSTANT number of DAC cycles over these")
        print("  triggers.  What that means depends on where the Trigger came from:")
        print("   * TRIG_EMIT_DAC=1 build, XS18->XS19 loopback: expected.  The pulse")
        print("     edge is already on the dac_axis_clk grid, so every downstream")
        print("     capture is phase-locked and BOTH paths are deterministic.  This")
        print("     says the capture+launch chain contributes no jitter of its own;")
        print("     it says nothing about an external Trigger.")
        print("   * external Trigger not locked to the board's reference: unexpected.")
        print("     The 48-phase model predicts a spread here, so re-check with more")
        print("     triggers before trusting it.")
    else:
        print(f"  The hmc_pl_clk hop added a VARIABLE {spread} DAC cycle(s) to the same")
        print("  physical XS19 edge, i.e. it was moving the launch by up to")
        print(f"  {spread * DAC_AXIS_PERIOD_NS:.1f} ns on its own.  Removing it is expected to take that")
        print("  term out of the scope measurement.")
        print(f"  (One DAC cycle = {DAC_AXIS_PERIOD_NS:.0f} ns; one hmc_pl_clk cycle ="
              f" {HMC_PL_CLK_PERIOD_NS:.4f} ns;")
        print("   the residual phase lattice between them is 5/12 = 0.4167 ns.)")

    start = values.get("trig_lat_start_delta")
    if start:
        print(f"  capture -> pc_started: {start} DAC cycles "
              f"({start * DAC_AXIS_PERIOD_NS:.1f} ns), fixed pipeline")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--role", default=os.environ.get("ILA_CAPTURE_ROLE", "slave"))
    parser.add_argument("--jtag-serial", default=os.environ.get("JTAG_SERIAL", "210512180082"))
    parser.add_argument("--ltx", default=None)
    parser.add_argument("--vivado", default=os.environ.get("VIVADO", "vivado"))
    parser.add_argument("--reuse-csv", action="store_true",
                        help="parse the previous capture instead of talking to the board")
    args = parser.parse_args()

    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    csv_path = REPORT_DIR / "latency.csv"
    tcl_path = REPORT_DIR / "latency.tcl"
    log_path = REPORT_DIR / "vivado.log"
    ltx = Path(args.ltx) if args.ltx else ROOT / "artifacts" / f"custom_xczu47dr_{args.role}.ltx"

    if not args.reuse_csv:
        if not ltx.is_file():
            print(f"ERROR: LTX not found: {ltx}")
            return 1
        jtag_target = f"localhost:3121/xilinx_tcf/Xilinx/{args.jtag_serial}"
        write_tcl(tcl_path, csv_path, ltx, jtag_target)
        with log_path.open("w", encoding="utf-8") as log:
            rc = subprocess.call([args.vivado, "-mode", "batch", "-notrace",
                                  "-source", str(tcl_path)], stdout=log, stderr=subprocess.STDOUT)
        if rc != 0 or not csv_path.is_file():
            print(f"ERROR: capture failed (exit {rc}); see {log_path}")
            return 1

    return report(parse_csv(csv_path))


if __name__ == "__main__":
    sys.exit(main())
