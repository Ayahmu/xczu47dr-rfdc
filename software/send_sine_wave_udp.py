#!/usr/bin/env python3
"""Compatibility wrapper for sine waveform UDP sending.

Prefer `send_waveform_udp.py sine` for new usage.
"""

import argparse
import sys
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import host  # noqa: E402
import waveform_tools  # noqa: E402


def make_sine(freq_hz: float, phase_rad: float, amplitude: int, sample_rate: float, encoding: str) -> np.ndarray:
    return waveform_tools.make_sine(freq_hz, phase_rad, amplitude, sample_rate, encoding=encoding)


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Generate and send X/Y sine waves over UDP.")
    ap.add_argument("--ip", default=host.DEFAULT_BOARD_IP, help="RFSoC board IP")
    ap.add_argument("--port", type=int, default=host.DEFAULT_BOARD_PORT, help="RFSoC UDP port")
    ap.add_argument("--udp-interface", default="enp225s0f0", help="PC NIC used for UDP sending")
    ap.add_argument("--udp-source-ip", default="192.168.1.10", help="PC source IP bound to the UDP socket")
    ap.add_argument("--output-dir", type=Path, default=Path("/tmp/opencode/rfsoc_sine_wave_send"))
    ap.add_argument("--timeout-s", type=float, default=5.0)
    ap.add_argument("--post-upload-sleep-s", type=float, default=0.5)
    ap.add_argument("--sample-rate-hz", "--sample-rate", dest="sample_rate_hz", type=float, default=host.DAC_XY_FS, help="DAC sample rate used to synthesize samples")
    ap.add_argument("--x-freq-hz", type=float, default=20e6, help="X-channel sine frequency")
    ap.add_argument("--y-freq-hz", type=float, default=20e6, help="Y-channel sine frequency")
    ap.add_argument("--x-phase-rad", type=float, default=0.0, help="X-channel phase in radians")
    ap.add_argument("--y-phase-rad", type=float, default=np.pi / 2.0, help="Y-channel phase in radians")
    ap.add_argument("--amplitude", type=int, default=20000, help="sine amplitude in DAC code units, max <= 32767")
    ap.add_argument("--encoding", choices=["signed", "offset-binary"], default="signed", help="Raw DAC code encoding")
    ap.add_argument("--loop", action="store_true", help="Replay the uploaded waveform continuously")
    ap.add_argument("--dry-run", action="store_true", help="Only write local waveform files")
    return ap.parse_args()


def main() -> int:
    args = parse_args()
    x = waveform_tools.make_sine(args.x_freq_hz, args.x_phase_rad, args.amplitude, args.sample_rate_hz, encoding=args.encoding)
    y = waveform_tools.make_sine(args.y_freq_hz, args.y_phase_rad, args.amplitude, args.sample_rate_hz, encoding=args.encoding)
    metadata = waveform_tools.build_metadata(
        mode="sine",
        sample_rate_hz=args.sample_rate_hz,
        encoding=args.encoding,
        loop=args.loop,
        x_freq_hz=args.x_freq_hz,
        y_freq_hz=args.y_freq_hz,
        x_phase_rad=args.x_phase_rad,
        y_phase_rad=args.y_phase_rad,
        amplitude=args.amplitude,
    )
    waveform_tools.save_waveform_artifacts(args.output_dir, x, y, metadata, prefix="sine")

    print(f"[sine] sample_rate_hz={args.sample_rate_hz} encoding={args.encoding}")
    print(f"[sine] X freq={args.x_freq_hz} Hz phase={args.x_phase_rad} amp={args.amplitude}")
    print(f"[sine] Y freq={args.y_freq_hz} Hz phase={args.y_phase_rad} amp={args.amplitude}")
    print(f"[sine] X first16={x[:16].tolist()}")
    print(f"[sine] Y first16={y[:16].tolist()}")
    print(f"[sine] output_dir={args.output_dir}")
    if args.dry_run:
        return 0

    waveform_tools.upload_and_play(
        x,
        y,
        ip=args.ip,
        port=args.port,
        udp_interface=args.udp_interface,
        udp_source_ip=args.udp_source_ip,
        timeout_s=args.timeout_s,
        post_upload_sleep_s=args.post_upload_sleep_s,
        output_dir=args.output_dir,
        loop=args.loop,
    )
    print("Done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
