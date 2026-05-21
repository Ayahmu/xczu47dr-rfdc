#!/usr/bin/env python3
"""Send deterministic golden-pattern waveforms for ILA byte-lane debug.

This script is intentionally simple: it uploads incrementing int16 samples to the
same X/Y DDR offsets used by the normal bringup scripts, prints the first-packet
golden values, then sends the standard BEGIN/PLAY/BEGIN/PLAY/END instruction
sequence. Use the printed values to compare against ILA probes stage by stage.
"""

import argparse
import sys
import time
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import host  # noqa: E402
import waveform_tools  # noqa: E402


def make_incrementing_pattern(sample_count: int = host.NUM_SAMPLES, start: int = 0) -> np.ndarray:
    return waveform_tools.make_incrementing_pattern(sample_count=sample_count, start=start)


def _first_two_u64(samples: np.ndarray) -> tuple[int, int]:
    return waveform_tools._first_two_u64(samples)


def expected_axi_wdata_hex(samples: np.ndarray) -> str:
    return waveform_tools.expected_axi_wdata_hex(samples)


def lane_bytes_hex(samples: np.ndarray) -> str:
    return waveform_tools.lane_bytes_hex(samples)


def play_instruction_words(channel: int, length_bytes: int, ddr_addr: int) -> tuple[int, int]:
    return waveform_tools.play_instruction_words(channel, length_bytes, ddr_addr)


def rtl_instruction_tdata_hex(words: tuple[int, int]) -> str:
    return waveform_tools.rtl_instruction_tdata_hex(words)


def print_golden_values(x: np.ndarray, y: np.ndarray) -> None:
    x_low, x_high = _first_two_u64(x)
    y_low, y_high = _first_two_u64(y)
    print("[golden] X first UDP packet words:")
    print(f"  magic = 0x{host.UDP_WAVE_DDR_MAGIC:016x}")
    print(f"  addr  = 0x{host.DDR_X_ADDR:016x}")
    print(f"  low   = 0x{x_low:016x}")
    print(f"  high  = 0x{x_high:016x}")
    print(f"  RTL AXI WDATA = {expected_axi_wdata_hex(x)}")
    print(f"  byte lanes    = {lane_bytes_hex(x)}")
    print("[golden] Y first UDP packet words:")
    print(f"  magic = 0x{host.UDP_WAVE_DDR_MAGIC:016x}")
    print(f"  addr  = 0x{host.DDR_Y_ADDR:016x}")
    print(f"  low   = 0x{y_low:016x}")
    print(f"  high  = 0x{y_high:016x}")
    print(f"  RTL AXI WDATA = {expected_axi_wdata_hex(y)}")
    print(f"  byte lanes    = {lane_bytes_hex(y)}")
    x_play = play_instruction_words(1, host.FIXED_DATA_BYTES, host.DDR_X_ADDR)
    y_play = play_instruction_words(2, host.FIXED_DATA_BYTES, host.DDR_Y_ADDR)
    print("[golden] PLAY instruction RTL tdata:")
    print(f"  ch1 = {rtl_instruction_tdata_hex(x_play)}")
    print(f"  ch2 = {rtl_instruction_tdata_hex(y_play)}")


def upload_and_play(args: argparse.Namespace) -> None:
    x = make_incrementing_pattern(start=args.x_start)
    y = make_incrementing_pattern(start=args.y_start)
    print_golden_values(x, y)
    if args.print_only:
        return

    ctrl = host.RFSocController(
        args.ip,
        port=args.port,
        transport="udp",
        udp_interface=args.udp_interface,
        udp_source_ip=args.udp_source_ip,
        timeout_s=args.timeout_s,
    )
    try:
        args.output_dir.mkdir(parents=True, exist_ok=True)
        ctrl.upload_waveform_udp(x, host.DDR_X_ADDR, str(args.output_dir / "x_golden_upload_hex.txt"))
        ctrl.upload_waveform_udp(y, host.DDR_Y_ADDR, str(args.output_dir / "y_golden_upload_hex.txt"))
        if args.post_upload_sleep_s > 0:
            time.sleep(args.post_upload_sleep_s)
        ctrl.send_instructions([
            [1, 1, 0, 0],
            [2, 1, host.FIXED_DATA_BYTES, host.DDR_X_ADDR],
            [1, 2, 0, 0],
            [2, 2, host.FIXED_DATA_BYTES, host.DDR_Y_ADDR],
            [3, 15, 0, 0, 1 if getattr(args, "loop", False) else 0],
        ])
    finally:
        ctrl.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ip", default=host.DEFAULT_BOARD_IP)
    parser.add_argument("--port", type=int, default=host.DEFAULT_BOARD_PORT)
    parser.add_argument("--udp-interface", default="enp225s0f0")
    parser.add_argument("--udp-source-ip", default="192.168.1.10")
    parser.add_argument("--timeout-s", type=float, default=5.0)
    parser.add_argument("--post-upload-sleep-s", type=float, default=0.5)
    parser.add_argument("--output-dir", type=Path, default=Path("/tmp/opencode/rfsoc_golden_pattern"))
    parser.add_argument("--x-start", type=int, default=0)
    parser.add_argument("--y-start", type=int, default=0x1000)
    parser.add_argument("--loop", action="store_true", help="Keep replaying the same uploaded waveform continuously")
    parser.add_argument("--print-only", "--dry-run", dest="print_only", action="store_true", help="Print expected ILA values without sending UDP packets")
    return parser.parse_args()


def main() -> int:
    upload_and_play(parse_args())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
