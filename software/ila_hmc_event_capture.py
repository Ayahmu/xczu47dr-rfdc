#!/usr/bin/env python3
"""Capture HMC PL_CLK event timestamps while launching one master pulse."""

from __future__ import annotations

import csv
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

from dr47.device import Dr47Device
from dr47.sequence import make_single_trigger_sequence
from dr47.waveforms import (
    iq_duration_to_interleaved_sample_count,
    make_iq_gaussian_sine_interleaved,
    place_interleaved_iq_in_record,
)


ROOT = Path(__file__).resolve().parents[1]
REPORT_DIR = ROOT / "ila_hmc_event_reports"
ARMED = REPORT_DIR / "armed.flag"
CSV_PATH = REPORT_DIR / "capture.csv"
TCL_PATH = REPORT_DIR / "capture.tcl"
VIVADO_LOG = REPORT_DIR / "vivado.log"

# User configuration: edit this constant before running the script.
CAPTURE_ROLE = "master"
BOARD_IP = "169.254.21.60" if CAPTURE_ROLE == "master" else "169.254.214.189"
UDP_INTERFACE = "enp1s0f0"
SOURCE_IP = "169.254.250.11"
JTAG_SERIAL = "210512180082" if CAPTURE_ROLE == "master" else "210512180081"
JTAG_TARGET = f"localhost:3121/xilinx_tcf/Xilinx/{JTAG_SERIAL}"
LTX_PATH = ROOT / "artifacts" / f"custom_xczu47dr_{CAPTURE_ROLE}.ltx"
VIVADO = "vivado"


def make_record() -> np.ndarray:
    sample_rate = 400e6
    duration = 256e-9
    active_count = iq_duration_to_interleaved_sample_count(duration, sample_rate)
    active = make_iq_gaussian_sine_interleaved(
        frequency_hz=0.0,
        phase_rad=0.0,
        amplitude=6553,
        sample_rate_hz=sample_rate,
        duration_s=duration,
        sample_count=active_count,
        fwhm_s=duration / 2.0,
        q_sign=-1,
        hls_xy_drag=False,
    )
    return place_interleaved_iq_in_record(
        active,
        delay_s=200e-9,
        record_duration_s=1024e-9,
        sample_rate_hz=sample_rate,
    )


def write_tcl() -> None:
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    for path in (ARMED, CSV_PATH, TCL_PATH):
        if path.exists():
            path.unlink()
    TCL_PATH.write_text(
        "\n".join(
            [
                "set_param messaging.defaultLimit 10000",
                "open_hw_manager",
                "connect_hw_server -allow_non_jtag -url localhost:3121",
                f"open_hw_target {JTAG_TARGET}",
                "set dev [lindex [get_hw_devices] 0]",
                "current_hw_device $dev",
                f"set_property PROBES.FILE {{{LTX_PATH}}} $dev",
                "refresh_hw_device $dev",
                "set ilas [get_hw_ilas -of_objects $dev]",
                "set ila {}",
                "foreach candidate $ilas {",
                "  set found [get_hw_probes *trigger_event_toggle_hmc* -of_objects $candidate]",
                "  if {[llength $found] > 0} { set ila $candidate; break }",
                "}",
                "if {$ila eq \"\"} { error \"HMC event ILA not found\" }",
                "puts \"Using HMC event ILA: [get_property NAME $ila]\"",
                "current_hw_ila $ila",
                f"set trig [lindex [get_hw_probes *trigger_event_toggle_hmc* -of_objects $ila] 0]",
                "if {$trig eq \"\"} { error \"trigger_event_toggle_hmc probe missing\" }",
                "set_property TRIGGER_COMPARE_VALUE {eq1'b1} $trig",
                f"set fp [open {{{ARMED}}} w]",
                "puts $fp armed",
                "close $fp",
                "run_hw_ila $ila",
                "wait_on_hw_ila $ila",
                "set data [upload_hw_ila_data $ila]",
                f"write_hw_ila_data -force -csv_file {{{CSV_PATH}}} $data",
                "close_hw_manager",
            ]
        )
        + "\n",
        encoding="utf-8",
    )


def drive_once() -> None:
    record = make_record()
    device = Dr47Device(
        ip=BOARD_IP,
        port=1234,
        udp_interface=UDP_INTERFACE,
        udp_source_ip=SOURCE_IP,
        timeout_s=1.0,
        retries=2,
        batch_mode=True,
    )
    try:
        device.connect()
        device.abort_mute()
        device.require_external_sync()
        deadline = time.monotonic() + 30.0
        while time.monotonic() < deadline:
            caps = device.status(refresh=True).capabilities
            if caps.rfdc_ready and caps.dac_mts_ready and caps.nco_sync_ready:
                break
            time.sleep(0.05)
        else:
            raise RuntimeError("master RFDC/MTS/NCO was not ready")
        device.set_xy_nco_frequency(1, 1.0)
        device.set_gain("xy", 1, 0.2, gain_type="norm")
        device.set_qc_on_off("xy", 1, "on")
        device.commit()
        device.upload_waveforms(
            {1: record},
            channel_sequences={1: make_single_trigger_sequence(record.size // 2)},
            wave_formats={1: "interleaved_iq"},
            auto_start=False,
            loop=False,
            instruction_repeats=1,
        )
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            raw = device.status(refresh=True).capabilities.raw
            if (
                int(raw.get("play_config_channel_mask", 0)) & 1
            ) and raw.get("play_pending_valid", False) and raw.get("play_prefill_ready", False):
                break
            time.sleep(0.02)
        else:
            raise RuntimeError("master waveform prefill did not complete")
        device.arm(channel_mask=1)
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            if device.status(refresh=True).state.value == "prepared":
                break
            time.sleep(0.02)
        else:
            raise RuntimeError("master did not enter PREPARED")
        if CAPTURE_ROLE == "master":
            device.trigger()
        else:
            raise RuntimeError(
                "slave ILA capture needs an independent external SYNC/Trigger source; "
                "the deleted dual-board example is no longer invoked automatically"
            )
        time.sleep(0.5)
    finally:
        try:
            device.abort_mute()
        except Exception:
            pass
        device.close()


def parse_csv() -> None:
    with CSV_PATH.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        rows = [row for row in reader if row.get("Sample in Buffer", "").strip().isdigit()]
    if not rows:
        raise RuntimeError("HMC event ILA CSV is empty")
    names = (
        "top_i/hmc_event_tick[63:0]",
        "top_i/sync_event_tick[63:0]",
        "top_i/trigger_capture_tick[63:0]",
        "top_i/trigger_launch_tick[63:0]",
    )
    for name in names:
        values = []
        for row in rows:
            raw = row.get(name)
            if raw:
                values.append(int(raw.strip().strip('"').replace("_", ""), 16))
        if values:
            print(f"{name}: first={values[0]} last={values[-1]} unique={len(set(values))}")
        else:
            print(f"{name}: not present in CSV")


def main() -> int:
    write_tcl()
    with VIVADO_LOG.open("w", encoding="utf-8") as log:
        process = subprocess.Popen([VIVADO, "-mode", "batch", "-source", str(TCL_PATH)], stdout=log, stderr=subprocess.STDOUT)
    deadline = time.monotonic() + 120.0
    while not ARMED.exists():
        if process.poll() is not None:
            raise RuntimeError(f"Vivado exited before ILA armed, code={process.returncode}")
        if time.monotonic() >= deadline:
            process.kill()
            raise TimeoutError("HMC event ILA did not arm")
        time.sleep(0.2)
    print("HMC event ILA armed; launching one master waveform")
    drive_once()
    process.wait(timeout=120.0)
    if process.returncode != 0:
        raise RuntimeError(f"Vivado ILA capture failed, code={process.returncode}; see {VIVADO_LOG}")
    parse_csv()
    print(f"PASS: HMC event capture written to {CSV_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
