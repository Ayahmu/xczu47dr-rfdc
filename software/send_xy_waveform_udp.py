#!/usr/bin/env python3
"""Compatibility wrapper for Gaussian burst waveform UDP sending.

Prefer `send_waveform_udp.py burst` for new usage.
"""

import argparse
import os
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import host  # noqa: E402
import waveform_tools  # noqa: E402


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ip", default=host.DEFAULT_BOARD_IP)
    ap.add_argument("--port", type=int, default=host.DEFAULT_BOARD_PORT)
    ap.add_argument("--udp-interface", default=os.environ.get("RFSOC_UDP_INTERFACE", "enp225s0f0"))
    ap.add_argument("--udp-source-ip", default=os.environ.get("RFSOC_UDP_SOURCE_IP", "192.168.1.10"))
    ap.add_argument("--output-dir", type=Path, default=Path("/tmp/opencode/rfsoc_xy_waveform_upload"))
    ap.add_argument("--timeout-s", type=float, default=5.0)
    ap.add_argument("--post-upload-sleep-s", type=float, default=0.5)
    ap.add_argument("--sample-rate-hz", "--sample-rate", dest="sample_rate_hz", type=float, default=host.DAC_XY_FS)
    ap.add_argument("--duration-s", type=float, default=120e-9)
    ap.add_argument("--x-delay-s", type=float, default=80e-9)
    ap.add_argument("--y-delay-s", type=float, default=120e-9)
    ap.add_argument("--x-freq-hz", type=float, default=80e6)
    ap.add_argument("--y-freq-hz", type=float, default=120e6)
    ap.add_argument("--x-phase-rad", type=float, default=0.0)
    ap.add_argument("--y-phase-rad", type=float, default=0.0)
    ap.add_argument("--amplitude", "--scale", dest="amplitude", type=int, default=24000)
    ap.add_argument("--loop", action="store_true", help="Replay the uploaded waveform continuously")
    ap.add_argument("--dry-run", action="store_true", help="Only write local waveform files")
    return ap.parse_args()


def main() -> int:
    args = parse_args()
    x = waveform_tools.make_gaussian_burst(args.x_freq_hz, args.x_phase_rad, args.amplitude, args.sample_rate_hz, args.duration_s, args.x_delay_s)
    y = waveform_tools.make_gaussian_burst(args.y_freq_hz, args.y_phase_rad, args.amplitude, args.sample_rate_hz, args.duration_s, args.y_delay_s)
    metadata = waveform_tools.build_metadata(
        mode="burst",
        sample_rate_hz=args.sample_rate_hz,
        encoding="signed",
        loop=args.loop,
        x_freq_hz=args.x_freq_hz,
        y_freq_hz=args.y_freq_hz,
        x_phase_rad=args.x_phase_rad,
        y_phase_rad=args.y_phase_rad,
        x_delay_s=args.x_delay_s,
        y_delay_s=args.y_delay_s,
        duration_s=args.duration_s,
        amplitude=args.amplitude,
    )
    waveform_tools.save_waveform_artifacts(args.output_dir, x, y, metadata, prefix="burst")
    print(f"[burst] sample_rate_hz={args.sample_rate_hz}")
    print(f"[burst] X min={int(x.min())} max={int(x.max())} first8={x[:8].tolist()}")
    print(f"[burst] Y min={int(y.min())} max={int(y.max())} first8={y[:8].tolist()}")
    print(f"[burst] output_dir={args.output_dir}")
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
