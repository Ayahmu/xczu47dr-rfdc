#!/usr/bin/env python3
"""Generate, save, upload, and play RFSoC DAC waveforms over UDP.

Use this as the main waveform sender. All frequency and sample-rate parameters
are explicit in Hz so it is clear what changes the generated samples.
"""

import argparse
import sys
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import host  # noqa: E402
import waveform_tools  # noqa: E402


def add_common_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--ip", default=host.DEFAULT_BOARD_IP, help="RFSoC board IPv4 address")
    parser.add_argument("--port", type=int, default=host.DEFAULT_BOARD_PORT, help="RFSoC UDP port")
    parser.add_argument("--udp-interface", default="enp225s0f0", help="PC NIC used for 10G UDP sending")
    parser.add_argument("--udp-source-ip", default="192.168.1.10", help="PC source IPv4 address bound to the UDP socket")
    parser.add_argument("--output-dir", type=Path, default=Path("/tmp/opencode/rfsoc_waveform_send"))
    parser.add_argument("--timeout-s", type=float, default=5.0)
    parser.add_argument("--post-upload-sleep-s", type=float, default=0.5)
    parser.add_argument("--sample-rate-hz", "--sample-rate", dest="sample_rate_hz", type=float, default=host.DAC_XY_FS, help="DAC sample rate used for waveform synthesis")
    parser.add_argument("--loop", action="store_true", help="Replay the uploaded waveform continuously")
    parser.add_argument("--wait-for-trigger", action="store_true", help="Do not auto-start; wait for PS/external trigger")
    parser.add_argument("--dry-run", action="store_true", help="Only generate local waveform files; do not send UDP packets")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="mode", required=True)

    sine = subparsers.add_parser("sine", help="continuous sine wave on X/Y")
    add_common_args(sine)
    sine.add_argument("--x-freq-hz", type=float, default=20e6, help="X-channel sine frequency")
    sine.add_argument("--y-freq-hz", type=float, default=20e6, help="Y-channel sine frequency")
    sine.add_argument("--x-phase-rad", type=float, default=0.0, help="X-channel phase in radians")
    sine.add_argument("--y-phase-rad", type=float, default=np.pi / 2.0, help="Y-channel phase in radians")
    sine.add_argument("--amplitude", type=int, default=20000, help="DAC code amplitude, 0..32767")
    sine.add_argument("--encoding", choices=["signed", "offset-binary"], default="signed")

    burst = subparsers.add_parser("burst", help="Gaussian-windowed RF bursts on X/Y")
    add_common_args(burst)
    burst.add_argument("--x-freq-hz", type=float, default=80e6, help="X-channel carrier frequency")
    burst.add_argument("--y-freq-hz", type=float, default=120e6, help="Y-channel carrier frequency")
    burst.add_argument("--x-phase-rad", type=float, default=0.0)
    burst.add_argument("--y-phase-rad", type=float, default=0.0)
    burst.add_argument("--x-delay-s", type=float, default=80e-9)
    burst.add_argument("--y-delay-s", type=float, default=120e-9)
    burst.add_argument("--duration-s", type=float, default=120e-9, help="Gaussian burst duration")
    burst.add_argument("--amplitude", type=int, default=24000, help="DAC code amplitude, 0..32767")

    golden = subparsers.add_parser("golden", help="incrementing int16 pattern for ILA/debug")
    add_common_args(golden)
    golden.add_argument("--x-start", type=int, default=0)
    golden.add_argument("--y-start", type=int, default=0x1000)

    return parser


def generate_waveforms(args: argparse.Namespace) -> tuple[np.ndarray, np.ndarray, dict]:
    if args.mode == "sine":
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
        return x, y, metadata

    if args.mode == "burst":
        x = waveform_tools.make_gaussian_burst(args.x_freq_hz, args.x_phase_rad, args.amplitude, args.sample_rate_hz, args.duration_s, args.x_delay_s)
        y = waveform_tools.make_gaussian_burst(args.y_freq_hz, args.y_phase_rad, args.amplitude, args.sample_rate_hz, args.duration_s, args.y_delay_s)
        if not np.any(x) or not np.any(y):
            raise ValueError("burst mode produced all-zero samples; check duration_s, delay_s, amplitude, and sample_rate_hz")
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
        return x, y, metadata

    if args.mode == "golden":
        x = waveform_tools.make_incrementing_pattern(start=args.x_start)
        y = waveform_tools.make_incrementing_pattern(start=args.y_start)
        metadata = waveform_tools.build_metadata(
            mode="golden",
            sample_rate_hz=args.sample_rate_hz,
            encoding="uint16-viewed-as-int16",
            loop=args.loop,
            x_start=args.x_start,
            y_start=args.y_start,
        )
        return x, y, metadata

    raise ValueError(f"Unsupported waveform mode: {args.mode}")


def main() -> int:
    args = build_parser().parse_args()
    x, y, metadata = generate_waveforms(args)
    waveform_tools.save_waveform_bundle(args.output_dir, x, y, metadata, stem=args.mode)

    print(f"[waveform] mode={args.mode} sample_rate_hz={args.sample_rate_hz}")
    print(f"[waveform] X min={int(x.min())} max={int(x.max())} first16={x[:16].tolist()}")
    print(f"[waveform] Y min={int(y.min())} max={int(y.max())} first16={y[:16].tolist()}")
    print(f"[waveform] output_dir={args.output_dir}")
    if args.dry_run:
        print("[waveform] dry-run: not sending UDP packets")
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
        auto_start=not args.wait_for_trigger,
    )
    print("Done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
