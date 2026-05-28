#!/usr/bin/env python3
"""Capture Vivado ILA data and compare RFDC samples against host artifacts."""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import host  # noqa: E402
import waveform_tools  # noqa: E402


CHANNELS = (1, 2, 3, 4)
DEFAULT_TRIGGER_PROBES = ("top_i/pc_trig_start", "top_i/pc_trig_pulse")
DEFAULT_VALID_PROBES = {
    1: ("top_i/dac_ch1_valid_gated", "top_i/dac_in_ch1_tvalid"),
    2: ("top_i/dac_ch2_valid_gated", "top_i/dac_in_ch2_tvalid"),
    3: ("top_i/dac_ch3_valid_gated", "top_i/dac_in_ch3_tvalid"),
    4: ("top_i/dac_ch4_valid_gated", "top_i/dac_in_ch4_tvalid"),
}
DEFAULT_DATA_PROBES = {
    1: ("top_i/dac_in_ch1_tdata",),
    2: ("top_i/dac_in_ch2_tdata",),
    3: ("top_i/dac_in_ch3_tdata",),
    4: ("top_i/dac_in_ch4_tdata",),
}
DEFAULT_DELAY_PROBES = {
    1: ("top_i/ch1_delay_dac", "top_i/ch1_delay_cycles"),
    2: ("top_i/ch2_delay_dac", "top_i/ch2_delay_cycles"),
    3: ("top_i/ch3_delay_dac", "top_i/ch3_delay_cycles"),
    4: ("top_i/ch4_delay_dac", "top_i/ch4_delay_cycles"),
}
DEFAULT_LEN_PROBES = {
    1: ("top_i/ch1_len_dac64",),
    2: ("top_i/ch2_len_dac64",),
    3: ("top_i/ch3_len_dac64",),
    4: ("top_i/ch4_len_dac64",),
}


@dataclass
class ProbeRef:
    logical: str
    name: str | None = None
    bit_columns: list[tuple[int, str]] = field(default_factory=list)

    @property
    def resolved(self) -> bool:
        return self.name is not None or bool(self.bit_columns)

    @property
    def label(self) -> str:
        if self.name is not None:
            return self.name
        if self.bit_columns:
            base = re.sub(r"\[\d+\]$", "", self.bit_columns[0][1])
            return f"{base}[bits]"
        return "<missing>"


@dataclass
class ChannelReport:
    channel: int
    valid_probe: str | None
    data_probe: str | None
    delay_probe: str | None
    len_probe: str | None
    first_valid_index: int | None
    delay_from_trigger_cycles: int | None
    expected_delay_cycles: int | None
    valid_cycles: int
    expected_valid_cycles: int | None
    valid_windows: list[tuple[int, int]]
    captured_samples: int
    expected_samples: int
    matched_samples: int
    mismatch_count: int
    first_mismatch: dict[str, Any] | None
    status: str
    notes: list[str]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Capture Vivado ILA data and compare CH1-CH4 RFDC stream data against saved Python waveform artifacts.",
    )
    parser.add_argument("--artifact-dir", type=Path, default=Path("software/waveform_out"), help="Directory containing ch1..ch4 waveform artifacts and metadata.")
    parser.add_argument("--csv", dest="csv_file", type=Path, help="Analyze an existing Vivado ILA CSV instead of running capture.")
    parser.add_argument("--capture", action="store_true", help="Run Vivado hardware-manager capture before analysis.")
    parser.add_argument("--out-dir", type=Path, default=Path("software/ila_reports"), help="Directory for generated Tcl, CSV, JSON, and Markdown reports.")
    parser.add_argument("--vivado", default="vivado", help="Vivado executable used for capture mode.")
    parser.add_argument("--hw-server", default="localhost:3121", help="Vivado hw_server URL.")
    parser.add_argument("--device-filter", default="", help="Substring used to select a hardware device.")
    parser.add_argument("--ila-filter", default="", help="Substring used to select a hardware ILA core.")
    parser.add_argument("--bit", type=Path, help="Optional bitstream to program before capture.")
    parser.add_argument("--ltx", type=Path, help="Optional probes file to apply before capture.")
    parser.add_argument("--program-mode", choices=("ask", "auto", "always", "never"), default="ask", help="How to handle FPGA programming before capture.")
    parser.add_argument("--yes", action="store_true", help="Answer yes to interactive programming confirmation prompts.")
    parser.add_argument("--send-after-arm", action="store_true", help="After the ILA is armed, upload artifacts and send playback instructions to trigger capture.")
    parser.add_argument("--ip", default=host.DEFAULT_BOARD_IP, help="Board IPv4 address used when --send-after-arm is set.")
    parser.add_argument("--port", type=int, default=host.DEFAULT_BOARD_PORT, help="Board UDP port used when --send-after-arm is set.")
    parser.add_argument("--udp-interface", default=host.DEFAULT_UDP_INTERFACE, help="PC NIC bound for UDP waveform upload.")
    parser.add_argument("--udp-source-ip", default=host.DEFAULT_UDP_SOURCE_IP, help="PC source IPv4 address bound for UDP waveform upload.")
    parser.add_argument("--post-upload-sleep-s", type=float, default=host.DEFAULT_UDP_WRITE_SETTLE_S, help="Delay between waveform upload and playback instructions.")
    parser.add_argument("--loop", action="store_true", help="Set the hardware loop bit in playback instructions.")
    parser.add_argument("--wait-for-trigger", action="store_true", help="Send a non-auto-start END instruction, then issue the host trigger packet.")
    parser.add_argument("--no-generate-default-artifacts", action="store_true", help="Fail instead of generating a default CH1-CH4 golden artifact bundle when --send-after-arm has no artifacts.")
    parser.add_argument("--capture-depth", type=int, default=4096, help="Requested ILA capture depth when the core supports CONTROL.DATA_DEPTH.")
    parser.add_argument("--trigger-position", type=int, default=1024, help="Requested ILA trigger position when the core supports CONTROL.TRIGGER_POSITION.")
    parser.add_argument("--timeout-s", type=int, default=120, help="Vivado capture process timeout in seconds.")
    parser.add_argument("--trigger-probe", help="Override trigger/reference probe name. Default prefers top_i/pc_trig_start.")
    parser.add_argument("--probe-map", type=Path, help="JSON map overriding logical probe names: trigger, ch1_valid, ch1_data, ...")
    parser.add_argument("--expected-delay-cycles", default="", help="Comma list such as ch1=0,ch2=32,ch3=64,ch4=96.")
    parser.add_argument("--setup-tcl", type=Path, help="Optional Tcl snippet sourced after ILA selection and before run_hw_ila.")
    parser.add_argument("--skip-trigger-setup", action="store_true", help="Do not set a default ILA trigger compare value; use the current Vivado ILA setup.")
    parser.add_argument("--report-prefix", default="ila_capture_report", help="Output report filename prefix.")
    return parser.parse_args()


def load_probe_map(path: Path | None) -> dict[str, str]:
    if path is None:
        return {}
    with path.open("r", encoding="utf-8") as f:
        raw = json.load(f)
    return {str(k): str(v) for k, v in raw.items()}


def parse_expected_delays(text: str) -> dict[int, int]:
    delays: dict[int, int] = {}
    if not text.strip():
        return delays
    for item in text.split(","):
        if not item.strip():
            continue
        key, sep, value = item.partition("=")
        if sep != "=":
            raise ValueError(f"Bad delay item {item!r}; expected chN=value")
        match = re.fullmatch(r"ch([1-4])", key.strip().lower())
        if match is None:
            raise ValueError(f"Bad channel in delay item {item!r}")
        delays[int(match.group(1))] = int(value.strip(), 0)
    return delays


def vivado_quote(path: Path | None) -> str:
    if path is None:
        return ""
    return str(path.resolve()).replace("\\", "/")


def write_capture_tcl(args: argparse.Namespace, csv_path: Path, tcl_path: Path, program_device: bool, armed_path: Path | None) -> None:
    bit = vivado_quote(args.bit)
    ltx = vivado_quote(args.ltx)
    setup_tcl = vivado_quote(args.setup_tcl)
    csv_out = vivado_quote(csv_path)
    device_filter = args.device_filter.replace("'", "")
    ila_filter = args.ila_filter.replace("'", "")
    lines = [
        "set_param messaging.defaultLimit 10000",
        "open_hw_manager",
        f"connect_hw_server -allow_non_jtag -url {args.hw_server}",
        "open_hw_target",
        "set devs [get_hw_devices]",
        f"set device_filter {{{device_filter}}}",
        "set dev [lindex $devs 0]",
        "if {$device_filter ne \"\"} {",
        "  foreach d $devs { if {[string first $device_filter [get_property NAME $d]] >= 0} { set dev $d; break } }",
        "}",
        "current_hw_device $dev",
        "refresh_hw_device $dev",
    ]
    if program_device and bit:
        lines.extend([
            f"set_property PROGRAM.FILE {{{bit}}} $dev",
            *( [f"set_property PROBES.FILE {{{ltx}}} $dev"] if ltx else [] ),
            "program_hw_devices $dev",
            "refresh_hw_device $dev",
        ])
    elif program_device and not bit:
        lines.append("error {Programming was requested but no bitstream was provided}")
    elif ltx:
        lines.extend([
            f"set_property PROBES.FILE {{{ltx}}} $dev",
            "refresh_hw_device $dev",
        ])
    trigger_for_select = (args.trigger_probe or DEFAULT_TRIGGER_PROBES[0]).replace("'", "")
    valid_for_select = DEFAULT_VALID_PROBES[1][0]
    data_for_select = DEFAULT_DATA_PROBES[1][0]
    lines.extend([
        "set raw_ilas [get_hw_ilas -of_objects $dev]",
        f"set ila_filter {{{ila_filter}}}",
        "if {[llength $raw_ilas] == 0} { error \"No ILA cores found. Program the design or check the LTX/bitstream match.\" }",
        "set ilas {}",
        "if {$ila_filter ne \"\"} {",
        "  foreach i $raw_ilas { if {[string first $ila_filter [get_property NAME $i]] >= 0} { lappend ilas $i } }",
        "} else {",
        "  set ilas $raw_ilas",
        "}",
        "if {[llength $ilas] == 0} { error \"No ILA cores matched the requested --ila-filter\" }",
        f"set preferred_probe_names {{{trigger_for_select} {valid_for_select} {data_for_select}}}",
        "set ila {}",
        "foreach candidate $ilas {",
        "  foreach probe_name $preferred_probe_names {",
        "    set found [get_hw_probes $probe_name -of_objects $candidate]",
        "    if {[llength $found] == 0} { set found [get_hw_probes *$probe_name* -of_objects $candidate] }",
        "    if {[llength $found] > 0} { set ila $candidate; break }",
        "  }",
        "  if {$ila ne \"\"} { break }",
        "}",
        "if {$ila eq \"\"} { set ila [lindex $ilas 0] }",
        "puts \"Using ILA: $ila\"",
        "current_hw_ila $ila",
        "set probes [get_hw_probes -of_objects $ila]",
        "if {[llength $probes] == 0} { error \"Selected ILA has no probes. Check that the LTX matches the programmed design.\" }",
        f"catch {{ set_property CONTROL.DATA_DEPTH {int(args.capture_depth)} $ila }}",
        f"catch {{ set_property CONTROL.TRIGGER_POSITION {int(args.trigger_position)} $ila }}",
    ])
    if not args.skip_trigger_setup:
        if args.trigger_probe:
            trigger_probe = args.trigger_probe
        else:
            trigger_probe = DEFAULT_TRIGGER_PROBES[0]
        lines.extend([
            f"set trigger_probe_name {{{trigger_probe}}}",
            "set trigger_probe [lindex [get_hw_probes $trigger_probe_name -of_objects $ila] 0]",
            "if {$trigger_probe eq \"\"} { set trigger_probe [lindex [get_hw_probes *$trigger_probe_name* -of_objects $ila] 0] }",
            "if {$trigger_probe eq \"\"} { error \"Missing ILA trigger probe: $trigger_probe_name\" }",
            "if {[catch { set_property TRIGGER_COMPARE_VALUE {eq1'b1} $trigger_probe } msg]} { error \"Failed to set trigger compare: $msg\" }",
        ])
    if setup_tcl:
        lines.append(f"source {{{setup_tcl}}}")
    lines.extend([
        "run_hw_ila $ila",
    ])
    if armed_path is not None:
        lines.extend([
            f"set armed_file {{{vivado_quote(armed_path)}}}",
            "set fp [open $armed_file w]",
            "puts $fp armed",
            "close $fp",
        ])
    lines.extend([
        "wait_on_hw_ila $ila",
        "set data [upload_hw_ila_data $ila]",
        f"write_hw_ila_data -force -csv_file {{{csv_out}}} $data",
        "close_hw_manager",
    ])
    tcl_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_preflight_tcl(args: argparse.Namespace, tcl_path: Path) -> None:
    ltx = vivado_quote(args.ltx)
    device_filter = args.device_filter.replace("'", "")
    ila_filter = args.ila_filter.replace("'", "")
    lines = [
        "set_param messaging.defaultLimit 10000",
        "open_hw_manager",
        f"connect_hw_server -allow_non_jtag -url {args.hw_server}",
        "open_hw_target",
        "set devs [get_hw_devices]",
        f"set device_filter {{{device_filter}}}",
        "set dev [lindex $devs 0]",
        "if {$device_filter ne \"\"} {",
        "  foreach d $devs { if {[string first $device_filter [get_property NAME $d]] >= 0} { set dev $d; break } }",
        "}",
        "current_hw_device $dev",
        "refresh_hw_device $dev",
    ]
    if ltx:
        lines.extend([
            f"set_property PROBES.FILE {{{ltx}}} $dev",
            "refresh_hw_device $dev",
        ])
    lines.extend([
        "set ilas [get_hw_ilas -of_objects $dev]",
        f"set ila_filter {{{ila_filter}}}",
        "if {$ila_filter ne \"\"} {",
        "  set matched {}",
        "  foreach i $ilas { if {[string first $ila_filter [get_property NAME $i]] >= 0} { lappend matched $i } }",
        "  set ilas $matched",
        "}",
        "puts \"ILA_COUNT=[llength $ilas]\"",
        "close_hw_manager",
        "if {[llength $ilas] == 0} { exit 2 }",
    ])
    tcl_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def preflight_design_present(args: argparse.Namespace) -> bool:
    tcl_path = args.out_dir / f"{args.report_prefix}_preflight.tcl"
    write_preflight_tcl(args, tcl_path)
    result = subprocess.run(
        [args.vivado, "-mode", "batch", "-source", str(tcl_path)],
        cwd=Path.cwd(),
        text=True,
        capture_output=True,
        timeout=args.timeout_s,
        check=False,
    )
    (args.out_dir / f"{args.report_prefix}_preflight_stdout.log").write_text(result.stdout, encoding="utf-8")
    (args.out_dir / f"{args.report_prefix}_preflight_stderr.log").write_text(result.stderr, encoding="utf-8")
    if result.returncode == 0:
        return True
    if result.returncode == 2:
        return False
    raise RuntimeError(f"Vivado preflight failed with exit code {result.returncode}; see {args.out_dir}")


def confirm_programming(args: argparse.Namespace) -> bool:
    if args.program_mode == "never":
        return False
    if args.program_mode == "always":
        return True
    design_present = preflight_design_present(args)
    if design_present:
        return False
    if args.program_mode == "auto":
        return True
    if args.yes:
        return True
    answer = input("No matching ILA design was detected. Program the FPGA with --bit now? [y/N] ").strip().lower()
    return answer in {"y", "yes"}


def send_artifacts_to_board(args: argparse.Namespace) -> None:
    waves = {channel: load_waveform(args.artifact_dir, channel) for channel in CHANNELS}
    ctrl = host.RFSocController(
        args.ip,
        port=args.port,
        transport="udp",
        udp_interface=args.udp_interface,
        udp_source_ip=args.udp_source_ip,
        timeout_s=float(args.timeout_s),
    )
    try:
        for channel, samples in waves.items():
            ddr_addr = waveform_tools.DEFAULT_CHANNEL_ADDRS[channel]
            dump_path = args.out_dir / f"{args.report_prefix}_ch{channel}_upload_hex.txt"
            ctrl.upload_waveform_udp(samples, ddr_addr, str(dump_path))
        if args.post_upload_sleep_s > 0:
            time.sleep(args.post_upload_sleep_s)
        commands = waveform_tools.build_play_commands(
            loop=args.loop,
            auto_start=not args.wait_for_trigger,
            channel_addrs=waveform_tools.DEFAULT_CHANNEL_ADDRS,
        )
        ctrl.send_instructions(commands)
        if args.wait_for_trigger:
            ctrl.trigger()
    finally:
        ctrl.close()


def wait_for_armed_file(path: Path, process: subprocess.Popen[str], timeout_s: int) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if path.exists():
            return
        if process.poll() is not None:
            raise RuntimeError("Vivado exited before arming the ILA; check the Vivado logs in the report directory")
        time.sleep(0.1)
    raise TimeoutError(f"ILA did not report armed state within {timeout_s} seconds")


def run_capture(args: argparse.Namespace) -> Path:
    args.out_dir.mkdir(parents=True, exist_ok=True)
    if args.send_after_arm:
        ensure_send_artifacts(args)
    if args.bit is None and args.program_mode in {"always", "auto"}:
        raise ValueError("--program-mode always/auto requires --bit")
    program_device = confirm_programming(args) if args.bit is not None else False
    csv_path = args.out_dir / f"{args.report_prefix}.csv"
    tcl_path = args.out_dir / f"{args.report_prefix}_capture.tcl"
    armed_path = args.out_dir / f"{args.report_prefix}.armed"
    if armed_path.exists():
        armed_path.unlink()
    write_capture_tcl(args, csv_path, tcl_path, program_device, armed_path)
    cmd = [args.vivado, "-mode", "batch", "-source", str(tcl_path)]
    process = subprocess.Popen(cmd, cwd=Path.cwd(), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        wait_for_armed_file(armed_path, process, args.timeout_s)
        if args.send_after_arm:
            send_artifacts_to_board(args)
        stdout, stderr = process.communicate(timeout=args.timeout_s)
    except Exception:
        process.kill()
        stdout, stderr = process.communicate()
        (args.out_dir / f"{args.report_prefix}_vivado_stdout.log").write_text(stdout, encoding="utf-8")
        (args.out_dir / f"{args.report_prefix}_vivado_stderr.log").write_text(stderr, encoding="utf-8")
        raise
    (args.out_dir / f"{args.report_prefix}_vivado_stdout.log").write_text(stdout, encoding="utf-8")
    (args.out_dir / f"{args.report_prefix}_vivado_stderr.log").write_text(stderr, encoding="utf-8")
    if process.returncode != 0:
        raise RuntimeError(f"Vivado capture failed with exit code {process.returncode}; see {args.out_dir}")
    if not csv_path.exists():
        raise RuntimeError(f"Vivado completed but did not create {csv_path}")
    return csv_path


def normalize_header(value: str) -> str:
    return value.strip().strip('"').strip()


def parse_scalar(value: str) -> int:
    text = value.strip().strip('"').replace("_", "")
    if text == "":
        return 0
    if text.lower().startswith("0x"):
        return int(text, 16)
    if re.fullmatch(r"[01xzXZ]+", text) and len(text) > 1:
        return int(text.replace("x", "0").replace("X", "0").replace("z", "0").replace("Z", "0"), 2)
    if re.fullmatch(r"[0-9a-fA-F]+", text) and (re.search(r"[a-fA-F]", text) or len(text) > 8 or (len(text) > 1 and text.startswith("0"))):
        return int(text, 16)
    try:
        return int(text, 0)
    except ValueError:
        return int(float(text))


def read_ila_csv(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    with path.open("r", encoding="utf-8-sig", newline="") as f:
        sample = f.read(4096)
        f.seek(0)
        try:
            dialect = csv.Sniffer().sniff(sample, delimiters=",;\t") if sample.strip() else csv.excel
        except csv.Error:
            dialect = csv.excel
        rows = list(csv.reader(f, dialect))
    header_index = None
    for idx, row in enumerate(rows):
        cleaned = [normalize_header(c) for c in row]
        if any("top_i/" in c for c in cleaned) or any("Sample" in c for c in cleaned):
            header_index = idx
            break
    if header_index is None:
        raise ValueError(f"Could not find an ILA CSV header in {path}")
    header = [normalize_header(c) for c in rows[header_index]]
    data: list[dict[str, str]] = []
    for row in rows[header_index + 1:]:
        if not any(str(c).strip() for c in row):
            continue
        if row and str(row[0]).strip().lower().startswith("radix"):
            continue
        padded = row + [""] * (len(header) - len(row))
        data.append({header[i]: padded[i] for i in range(len(header))})
    return header, data


def resolve_probe(header: list[str], logical: str, candidates: tuple[str, ...], probe_map: dict[str, str]) -> ProbeRef:
    names = [probe_map[logical]] if logical in probe_map else list(candidates)
    header_set = set(header)
    for name in names:
        if name in header_set:
            return ProbeRef(logical=logical, name=name)
    for name in names:
        suffix_matches = [h for h in header if h.endswith(name)]
        if suffix_matches:
            return ProbeRef(logical=logical, name=suffix_matches[0])
        bus_pattern = re.compile(re.escape(name) + r"\[\d+:\d+\]$")
        bus_matches = [h for h in header if bus_pattern.search(h)]
        if bus_matches:
            return ProbeRef(logical=logical, name=bus_matches[0])
        bit_matches: list[tuple[int, str]] = []
        bit_pattern = re.compile(re.escape(name) + r"\[(\d+)\]$")
        for h in header:
            m = bit_pattern.search(h)
            if m:
                bit_matches.append((int(m.group(1)), h))
        if bit_matches:
            return ProbeRef(logical=logical, bit_columns=sorted(bit_matches))
    return ProbeRef(logical=logical)


def resolve_trigger(header: list[str], rows: list[dict[str, str]], candidates: tuple[str, ...], probe_map: dict[str, str]) -> tuple[ProbeRef, list[int], int | None]:
    first_resolved: tuple[ProbeRef, list[int], int | None] | None = None
    for candidate in candidates:
        probe = resolve_probe(header, "trigger", (candidate,), probe_map)
        if not probe.resolved:
            continue
        values = column_values(rows, probe)
        index = rising_edge_index(values)
        current = (probe, values, index)
        if first_resolved is None:
            first_resolved = current
        if index is not None:
            return current
    if first_resolved is not None:
        return first_resolved
    return ProbeRef(logical="trigger"), [], None


def column_values(rows: list[dict[str, str]], probe: ProbeRef) -> list[int]:
    if probe.name is not None:
        return [parse_scalar(row.get(probe.name, "0")) for row in rows]
    values: list[int] = []
    for row in rows:
        acc = 0
        for bit, column in probe.bit_columns:
            acc |= (parse_scalar(row.get(column, "0")) & 1) << bit
        values.append(acc)
    return values


def rising_edge_index(values: list[int]) -> int | None:
    prev = 0
    for idx, value in enumerate(values):
        bit = 1 if value else 0
        if bit and not prev:
            return idx
        prev = bit
    return None


def valid_windows(valid: list[int]) -> list[tuple[int, int]]:
    windows: list[tuple[int, int]] = []
    start: int | None = None
    for idx, value in enumerate(valid):
        active = bool(value)
        if active and start is None:
            start = idx
        elif not active and start is not None:
            windows.append((start, idx - 1))
            start = None
    if start is not None:
        windows.append((start, len(valid) - 1))
    return windows


def load_metadata(artifact_dir: Path) -> dict[str, Any]:
    candidates = sorted(artifact_dir.glob("*_metadata.json")) + sorted(artifact_dir.glob("metadata.json"))
    if not candidates:
        return {}
    with candidates[0].open("r", encoding="utf-8") as f:
        return json.load(f)


def load_waveform(artifact_dir: Path, channel: int) -> np.ndarray:
    stem = f"ch{channel}_waveform"
    for suffix in (".npy", ".bin", ".csv"):
        path = artifact_dir / f"{stem}{suffix}"
        if not path.exists():
            continue
        if suffix == ".npy":
            return np.load(path).astype(np.int16)
        if suffix == ".bin":
            return np.frombuffer(path.read_bytes(), dtype="<i2").astype(np.int16)
        values: list[int] = []
        with path.open("r", encoding="utf-8") as f:
            reader = csv.reader(f)
            for row in reader:
                if not row:
                    continue
                try:
                    values.append(int(float(row[-1])))
                except ValueError:
                    continue
        return np.asarray(values, dtype=np.int16)
    legacy = "x_waveform" if channel == 1 else "y_waveform" if channel == 2 else stem
    for suffix in (".npy", ".bin", ".csv"):
        path = artifact_dir / f"{legacy}{suffix}"
        if path.exists():
            return load_waveform_file(path)
    raise FileNotFoundError(f"No waveform artifact found for CH{channel} in {artifact_dir}")


def load_waveform_file(path: Path) -> np.ndarray:
    if path.suffix == ".npy":
        return np.load(path).astype(np.int16)
    if path.suffix == ".bin":
        return np.frombuffer(path.read_bytes(), dtype="<i2").astype(np.int16)
    values: list[int] = []
    with path.open("r", encoding="utf-8") as f:
        for row in csv.reader(f):
            if not row:
                continue
            try:
                values.append(int(float(row[-1])))
            except ValueError:
                continue
    return np.asarray(values, dtype=np.int16)


def available_waveform_channels(artifact_dir: Path) -> set[int]:
    found: set[int] = set()
    for channel in CHANNELS:
        stems = [artifact_dir / f"ch{channel}_waveform"]
        if channel == 1:
            stems.append(artifact_dir / "x_waveform")
        if channel == 2:
            stems.append(artifact_dir / "y_waveform")
        for stem in stems:
            if stem.with_suffix(".npy").exists() or stem.with_suffix(".bin").exists() or stem.with_suffix(".csv").exists():
                found.add(channel)
                break
    return found


def generate_default_artifacts(args: argparse.Namespace) -> None:
    args.artifact_dir.mkdir(parents=True, exist_ok=True)
    ch1 = waveform_tools.make_incrementing_pattern(start=0x0000)
    ch2 = waveform_tools.make_incrementing_pattern(start=0x1000)
    ch3 = waveform_tools.make_incrementing_pattern(start=0x2000)
    ch4 = waveform_tools.make_incrementing_pattern(start=0x3000)
    metadata = waveform_tools.build_metadata(
        mode="ila-golden",
        sample_rate_hz=host.DAC_XY_FS,
        encoding="signed",
        loop=args.loop,
        generated_by="ila_capture_report.py",
        notes="Auto-generated because --send-after-arm had no CH1-CH4 waveform artifacts.",
    )
    waveform_tools.save_waveform_bundle(args.artifact_dir, ch1, ch2, metadata, stem="waveform", ch3=ch3, ch4=ch4)


def ensure_send_artifacts(args: argparse.Namespace) -> None:
    found = available_waveform_channels(args.artifact_dir)
    if found == set(CHANNELS):
        return
    if not found and not args.no_generate_default_artifacts:
        generate_default_artifacts(args)
        print(f"[artifact] Generated default CH1-CH4 golden waveform bundle in {args.artifact_dir}")
        return
    missing = ", ".join(f"CH{channel}" for channel in CHANNELS if channel not in found)
    raise FileNotFoundError(
        f"Missing waveform artifacts for {missing} in {args.artifact_dir}. "
        "Generate them with send_waveform_udp.py/GUI first, or use an empty artifact directory so the ILA script can create its default golden bundle."
    )


def samples_from_words(words: list[int]) -> np.ndarray:
    data = bytearray()
    for word in words:
        data.extend((int(word) & 0xFFFFFFFFFFFFFFFF).to_bytes(8, byteorder="little", signed=False))
    return np.frombuffer(bytes(data), dtype="<i2").astype(np.int16)


def compare_samples(captured: np.ndarray, expected: np.ndarray) -> tuple[int, int, dict[str, Any] | None]:
    limit = min(len(captured), len(expected))
    mismatch_indices = np.nonzero(captured[:limit] != expected[:limit])[0]
    mismatch_count = int(len(mismatch_indices) + abs(len(captured) - len(expected)))
    if mismatch_count == 0:
        return limit, 0, None
    if len(mismatch_indices):
        idx = int(mismatch_indices[0])
        first = {"sample_index": idx, "captured": int(captured[idx]), "expected": int(expected[idx])}
    else:
        idx = limit
        first = {"sample_index": idx, "captured": None if idx >= len(captured) else int(captured[idx]), "expected": None if idx >= len(expected) else int(expected[idx])}
    return limit - int(len(mismatch_indices)), mismatch_count, first


def expected_valid_cycles(metadata: dict[str, Any], expected: np.ndarray, channel: int) -> int:
    bytes_key = f"ch{channel}_bytes_per_channel"
    raw_bytes = metadata.get(bytes_key, metadata.get("bytes_per_channel"))
    if raw_bytes is None:
        raw_bytes = int(expected.size) * 2
    return int(math.ceil(int(raw_bytes) / 8.0))


def metadata_delay(metadata: dict[str, Any], channel: int) -> int | None:
    keys = (
        f"ch{channel}_instruction_delay_cycles",
        f"ch{channel}_delay_cycles",
        f"channel_{channel}_instruction_delay_cycles",
    )
    for key in keys:
        if key in metadata:
            return int(metadata[key])
    return None


def analyze(args: argparse.Namespace, csv_path: Path) -> tuple[dict[str, Any], str]:
    probe_map = load_probe_map(args.probe_map)
    expected_delays = parse_expected_delays(args.expected_delay_cycles)
    metadata = load_metadata(args.artifact_dir)
    header, rows = read_ila_csv(csv_path)
    if not rows:
        raise ValueError(f"No sample rows found in {csv_path}")

    trigger_candidates = (args.trigger_probe,) if args.trigger_probe else DEFAULT_TRIGGER_PROBES + ("TRIGGER",)
    trigger_probe, trigger_values, trigger_index = resolve_trigger(header, rows, tuple(p for p in trigger_candidates if p), probe_map)

    channels: list[ChannelReport] = []
    missing_probes: list[str] = []
    for channel in CHANNELS:
        expected = load_waveform(args.artifact_dir, channel)
        valid_probe = resolve_probe(header, f"ch{channel}_valid", DEFAULT_VALID_PROBES[channel], probe_map)
        data_probe = resolve_probe(header, f"ch{channel}_data", DEFAULT_DATA_PROBES[channel], probe_map)
        delay_probe = resolve_probe(header, f"ch{channel}_delay", DEFAULT_DELAY_PROBES[channel], probe_map)
        len_probe = resolve_probe(header, f"ch{channel}_len", DEFAULT_LEN_PROBES[channel], probe_map)

        notes: list[str] = []
        if not valid_probe.resolved:
            missing_probes.append(f"ch{channel}_valid")
            notes.append("valid probe missing")
        if not data_probe.resolved:
            missing_probes.append(f"ch{channel}_data")
            notes.append("data probe missing")

        valid_values = column_values(rows, valid_probe) if valid_probe.resolved else [0] * len(rows)
        data_values = column_values(rows, data_probe) if data_probe.resolved else []
        windows = valid_windows(valid_values)
        valid_indices = [idx for idx, value in enumerate(valid_values) if value]
        words = [data_values[idx] for idx in valid_indices if idx < len(data_values)]
        captured = samples_from_words(words)
        expected_cycles = expected_valid_cycles(metadata, expected, channel)
        matched, mismatches, first_mismatch = compare_samples(captured[: expected.size], expected)

        observed_delay = None
        first_valid = valid_indices[0] if valid_indices else None
        if trigger_index is not None and first_valid is not None:
            observed_delay = first_valid - trigger_index
        expected_delay = expected_delays.get(channel, metadata_delay(metadata, channel))
        if len(windows) > 1:
            notes.append(f"valid has {len(windows)} windows")
        if expected_delay is None:
            notes.append("expected delay not provided; observed delay reported only")
        if delay_probe.resolved and trigger_index is not None:
            values = column_values(rows, delay_probe)
            if trigger_index < len(values):
                notes.append(f"captured delay probe near trigger={values[trigger_index]}")
        if len_probe.resolved and trigger_index is not None:
            len_values = column_values(rows, len_probe)
            if trigger_index < len(len_values):
                notes.append(f"captured len probe near trigger={len_values[trigger_index]}")

        checks_ok = bool(valid_probe.resolved and data_probe.resolved)
        checks_ok = checks_ok and len(valid_indices) == expected_cycles and mismatches == 0
        if expected_delay is not None:
            checks_ok = checks_ok and observed_delay == expected_delay
        status = "PASS" if checks_ok else "FAIL"
        channels.append(
            ChannelReport(
                channel=channel,
                valid_probe=valid_probe.label if valid_probe.resolved else None,
                data_probe=data_probe.label if data_probe.resolved else None,
                delay_probe=delay_probe.label if delay_probe.resolved else None,
                len_probe=len_probe.label if len_probe.resolved else None,
                first_valid_index=first_valid,
                delay_from_trigger_cycles=observed_delay,
                expected_delay_cycles=expected_delay,
                valid_cycles=len(valid_indices),
                expected_valid_cycles=expected_cycles,
                valid_windows=windows,
                captured_samples=int(captured.size),
                expected_samples=int(expected.size),
                matched_samples=matched,
                mismatch_count=mismatches,
                first_mismatch=first_mismatch,
                status=status,
                notes=notes,
            )
        )

    overall = "PASS" if trigger_probe.resolved and trigger_index is not None and all(c.status == "PASS" for c in channels) else "FAIL"
    details = {
        "overall_status": overall,
        "csv": str(csv_path),
        "artifact_dir": str(args.artifact_dir),
        "sample_rows": len(rows),
        "trigger_probe": trigger_probe.label if trigger_probe.resolved else None,
        "trigger_index": trigger_index,
        "missing_probes": missing_probes + ([] if trigger_probe.resolved else ["trigger"]),
        "metadata": metadata,
        "channels": [c.__dict__ for c in channels],
    }
    return details, render_markdown(details)


def render_markdown(details: dict[str, Any]) -> str:
    def note_to_zh(note: str) -> str:
        if note == "valid probe missing":
            return "valid probe 缺失"
        if note == "data probe missing":
            return "data probe 缺失"
        if note == "expected delay not provided; observed delay reported only":
            return "未提供期望延迟，仅报告观测到的延迟"
        if note.startswith("valid has ") and note.endswith(" windows"):
            return note.replace("valid has", "valid 出现").replace("windows", "个窗口")
        if note.startswith("captured delay probe near trigger="):
            return note.replace("captured delay probe near trigger=", "trigger 附近采集到的 delay probe=")
        if note.startswith("captured len probe near trigger="):
            return note.replace("captured len probe near trigger=", "trigger 附近采集到的 length probe=")
        return note

    lines = [
        "# ILA 采集报告",
        "",
        f"总体状态：**{details['overall_status']}**",
        "",
        "## 采集摘要",
        "",
        f"- CSV: `{details['csv']}`",
        f"- 波形目录：`{details['artifact_dir']}`",
        f"- 采样行数：`{details['sample_rows']}`",
        f"- 触发 probe：`{details.get('trigger_probe')}`",
        f"- 触发位置：`{details.get('trigger_index')}`",
    ]
    if details["missing_probes"]:
        lines.append(f"- 缺失 probes：`{', '.join(details['missing_probes'])}`")
    lines.extend(["", "## 通道检查", ""])
    for c in details["channels"]:
        lines.extend([
            f"### CH{c['channel']} - {c['status']}",
            "",
            f"- Valid probe：`{c['valid_probe']}`",
            f"- Data probe：`{c['data_probe']}`",
            f"- 首个 valid 位置：`{c['first_valid_index']}`",
            f"- 触发到 valid 的延迟周期：`{c['delay_from_trigger_cycles']}`",
            f"- 期望延迟周期：`{c['expected_delay_cycles']}`",
            f"- Valid 周期数：`{c['valid_cycles']}` / 期望 `{c['expected_valid_cycles']}`",
            f"- Valid 窗口内采样数：`{c['captured_samples']}` / 期望 `{c['expected_samples']}`",
            f"- 逐样本匹配数：`{c['matched_samples']}`",
            f"- 不匹配数量：`{c['mismatch_count']}`",
            f"- Valid 窗口：`{c['valid_windows']}`",
        ])
        if c["first_mismatch"] is not None:
            lines.append(f"- 首个不匹配样本：`{c['first_mismatch']}`")
        if c["notes"]:
            lines.append(f"- 备注：`{'; '.join(note_to_zh(note) for note in c['notes'])}`")
        lines.append("")
    lines.extend([
        "## 结果解释",
        "",
        "PASS 表示脚本找到了触发/参考事件，所有通道都产生了期望数量的 RFDC-facing 64-bit valid 周期，并且 valid 窗口内采集到的每个 int16 样本都与 Python 侧波形文件完全一致。若未显式提供期望延迟周期，报告只展示观测到的延迟，不会仅因缺少期望延迟而判定失败。",
        "",
    ])
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    if not args.capture and args.csv_file is None:
        raise SystemExit("Use --capture to collect from hardware or --csv to analyze an existing ILA CSV.")
    if args.capture and shutil.which(args.vivado) is None:
        raise SystemExit(f"Vivado executable not found: {args.vivado}")
    args.out_dir.mkdir(parents=True, exist_ok=True)
    csv_path = run_capture(args) if args.capture else args.csv_file
    assert csv_path is not None
    details, markdown = analyze(args, csv_path)
    json_path = args.out_dir / f"{args.report_prefix}.json"
    md_path = args.out_dir / f"{args.report_prefix}.md"
    json_path.write_text(json.dumps(details, indent=2) + "\n", encoding="utf-8")
    md_path.write_text(markdown, encoding="utf-8")
    print(f"overall_status={details['overall_status']}")
    print(f"markdown_report={md_path}")
    print(f"json_report={json_path}")
    return 0 if details["overall_status"] == "PASS" else 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
