#!/usr/bin/env python3
"""Generate, save, upload, and play RFSoC DAC waveforms over UDP.

Use this as the main waveform sender. It targets the custom four-channel DAC
mapping CH1/CH2/CH3/CH4 -> DAC20/DAC22/DAC30/DAC32.
"""

import argparse
import sys
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import host  # noqa: E402
import waveform_tools  # noqa: E402


CHANNEL_DEFAULTS = {
    1: {"freq_hz": 20e6, "phase_rad": 0.0, "delay_s": 80e-9, "start": 0x0000},
    2: {"freq_hz": 20e6, "phase_rad": np.pi / 2.0, "delay_s": 120e-9, "start": 0x1000},
    3: {"freq_hz": 20e6, "phase_rad": 0.0, "delay_s": 160e-9, "start": 0x2000},
    4: {"freq_hz": 20e6, "phase_rad": np.pi / 2.0, "delay_s": 200e-9, "start": 0x3000},
}


def add_common_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--ip", default=host.DEFAULT_BOARD_IP, help="RFSoC board IPv4 address")
    parser.add_argument("--port", type=int, default=host.DEFAULT_BOARD_PORT, help="RFSoC UDP port")
    parser.add_argument("--udp-interface", default="enp225s0f0", help="PC NIC used for 10G UDP sending")
    parser.add_argument("--udp-source-ip", default="192.168.1.10", help="PC source IPv4 address bound to the UDP socket")
    parser.add_argument("--output-dir", type=Path, default=Path("/tmp/opencode/rfsoc_waveform_send"))
    parser.add_argument("--timeout-s", type=float, default=5.0)
    parser.add_argument("--post-upload-sleep-s", type=float, default=0.5)
    parser.add_argument("--sample-rate-hz", "--sample-rate", dest="sample_rate_hz", type=float, default=host.DAC_XY_FS, help="DAC sample rate used for waveform synthesis")
    parser.add_argument("--axis-freq-hz", type=float, default=host.DAC_AXIS_HZ, help="DAC AXIS clock used to convert hardware delay ns to cycles")
    parser.add_argument("--loop", action="store_true", help="Replay the uploaded waveform continuously")
    parser.add_argument("--wait-for-trigger", action="store_true", help="Do not auto-start; wait for PS/external trigger")
    parser.add_argument("--dry-run", action="store_true", help="Only generate local waveform files; do not send UDP packets")


def add_four_channel_sine_args(parser: argparse.ArgumentParser) -> None:
    for channel in range(1, 5):
        defaults = CHANNEL_DEFAULTS[channel]
        parser.add_argument(f"--ch{channel}-freq-hz", type=float, default=defaults["freq_hz"], help=f"CH{channel} sine frequency")
        parser.add_argument(f"--ch{channel}-phase-rad", type=float, default=defaults["phase_rad"], help=f"CH{channel} phase in radians")
    parser.add_argument("--x-freq-hz", type=float, default=None, help="Legacy alias for --ch1-freq-hz")
    parser.add_argument("--y-freq-hz", type=float, default=None, help="Legacy alias for --ch2-freq-hz")
    parser.add_argument("--x-phase-rad", type=float, default=None, help="Legacy alias for --ch1-phase-rad")
    parser.add_argument("--y-phase-rad", type=float, default=None, help="Legacy alias for --ch2-phase-rad")


def add_four_channel_burst_args(parser: argparse.ArgumentParser) -> None:
    for channel in range(1, 5):
        defaults = CHANNEL_DEFAULTS[channel]
        parser.add_argument(f"--ch{channel}-freq-hz", type=float, default=defaults["freq_hz"], help=f"CH{channel} carrier frequency")
        parser.add_argument(f"--ch{channel}-phase-rad", type=float, default=defaults["phase_rad"])
        parser.add_argument(f"--ch{channel}-delay-s", type=float, default=defaults["delay_s"])
    parser.add_argument("--x-freq-hz", type=float, default=None, help="Legacy alias for --ch1-freq-hz")
    parser.add_argument("--y-freq-hz", type=float, default=None, help="Legacy alias for --ch2-freq-hz")
    parser.add_argument("--x-phase-rad", type=float, default=None, help="Legacy alias for --ch1-phase-rad")
    parser.add_argument("--y-phase-rad", type=float, default=None, help="Legacy alias for --ch2-phase-rad")
    parser.add_argument("--x-delay-s", type=float, default=None, help="Legacy alias for --ch1-delay-s")
    parser.add_argument("--y-delay-s", type=float, default=None, help="Legacy alias for --ch2-delay-s")


def add_four_channel_golden_args(parser: argparse.ArgumentParser) -> None:
    for channel in range(1, 5):
        parser.add_argument(f"--ch{channel}-start", type=int, default=CHANNEL_DEFAULTS[channel]["start"])
    parser.add_argument("--x-start", type=int, default=None, help="Legacy alias for --ch1-start")
    parser.add_argument("--y-start", type=int, default=None, help="Legacy alias for --ch2-start")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="mode", required=True)

    sine = subparsers.add_parser("sine", help="continuous sine wave on CH1-CH4")
    add_common_args(sine)
    add_four_channel_sine_args(sine)
    sine.add_argument("--amplitude", type=int, default=20000, help="DAC code amplitude, 0..32767")
    sine.add_argument("--encoding", choices=["signed", "offset-binary"], default="signed")

    burst = subparsers.add_parser("burst", help="Gaussian-windowed RF bursts on CH1-CH4")
    add_common_args(burst)
    add_four_channel_burst_args(burst)
    burst.add_argument("--duration-s", type=float, default=120e-9, help="Gaussian burst duration")
    burst.add_argument("--amplitude", type=int, default=24000, help="DAC code amplitude, 0..32767")

    golden = subparsers.add_parser("golden", help="incrementing int16 pattern for ILA/debug")
    add_common_args(golden)
    add_four_channel_golden_args(golden)

    return parser


def _arg(args: argparse.Namespace, name: str) -> float | int:
    return getattr(args, name)


def _channel_value(args: argparse.Namespace, base_name: str, channel: int) -> float | int:
    if channel == 1:
        legacy = getattr(args, f"x_{base_name}", None)
        if legacy is not None:
            return legacy
    if channel == 2:
        legacy = getattr(args, f"y_{base_name}", None)
        if legacy is not None:
            return legacy
    return _arg(args, f"ch{channel}_{base_name}")


def _channel_key(channel: int, suffix: str) -> str:
    return f"ch{channel}_{suffix}"


def generate_waveforms(args: argparse.Namespace) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, dict]:
    if args.mode == "sine":
        waves = tuple(
            waveform_tools.make_sine(
                float(_channel_value(args, "freq_hz", channel)),
                float(_channel_value(args, "phase_rad", channel)),
                args.amplitude,
                args.sample_rate_hz,
                encoding=args.encoding,
            )
            for channel in range(1, 5)
        )
        metadata = waveform_tools.build_metadata(
            mode="sine",
            sample_rate_hz=args.sample_rate_hz,
            encoding=args.encoding,
            loop=args.loop,
            amplitude=args.amplitude,
            **{_channel_key(channel, "freq_hz"): float(_channel_value(args, "freq_hz", channel)) for channel in range(1, 5)},
            **{_channel_key(channel, "phase_rad"): float(_channel_value(args, "phase_rad", channel)) for channel in range(1, 5)},
        )
        return waves[0], waves[1], waves[2], waves[3], metadata

    if args.mode == "burst":
        waves = tuple(
            waveform_tools.make_gaussian_burst(
                float(_channel_value(args, "freq_hz", channel)),
                float(_channel_value(args, "phase_rad", channel)),
                args.amplitude,
                args.sample_rate_hz,
                args.duration_s,
            )
            for channel in range(1, 5)
        )
        if not all(np.any(wave) for wave in waves):
            raise ValueError("burst mode produced all-zero samples; check duration_s, channel delays, amplitude, and sample_rate_hz")
        metadata = waveform_tools.build_metadata(
            mode="burst",
            sample_rate_hz=args.sample_rate_hz,
            axis_freq_hz=args.axis_freq_hz,
            encoding="signed",
            loop=args.loop,
            duration_s=args.duration_s,
            amplitude=args.amplitude,
            **{_channel_key(channel, "freq_hz"): float(_channel_value(args, "freq_hz", channel)) for channel in range(1, 5)},
            **{_channel_key(channel, "phase_rad"): float(_channel_value(args, "phase_rad", channel)) for channel in range(1, 5)},
            **{_channel_key(channel, "delay_s"): float(_channel_value(args, "delay_s", channel)) for channel in range(1, 5)},
            **{
                _channel_key(channel, "delay_cycles"): waveform_tools.delay_seconds_to_axis_cycles_by_freq(
                    float(_channel_value(args, "delay_s", channel)), args.axis_freq_hz
                )
                for channel in range(1, 5)
            },
        )
        return waves[0], waves[1], waves[2], waves[3], metadata

    if args.mode == "golden":
        waves = tuple(
            waveform_tools.make_incrementing_pattern(start=int(_channel_value(args, "start", channel)))
            for channel in range(1, 5)
        )
        metadata = waveform_tools.build_metadata(
            mode="golden",
            sample_rate_hz=args.sample_rate_hz,
            encoding="uint16-viewed-as-int16",
            loop=args.loop,
            **{_channel_key(channel, "start"): int(_channel_value(args, "start", channel)) for channel in range(1, 5)},
        )
        return waves[0], waves[1], waves[2], waves[3], metadata

    raise ValueError(f"Unsupported waveform mode: {args.mode}")


def main() -> int:
    args = build_parser().parse_args()
    ch1, ch2, ch3, ch4, metadata = generate_waveforms(args)
    waveform_tools.save_waveform_bundle(args.output_dir, ch1, ch2, metadata, stem=args.mode, ch3=ch3, ch4=ch4)

    print(f"[waveform] mode={args.mode} sample_rate_hz={args.sample_rate_hz}")
    for channel, wave in enumerate((ch1, ch2, ch3, ch4), start=1):
        print(f"[waveform] CH{channel} min={int(wave.min())} max={int(wave.max())} first16={wave[:16].tolist()}")
    print(f"[waveform] output_dir={args.output_dir}")
    if args.dry_run:
        print("[waveform] dry-run: not sending UDP packets")
        return 0

    waveform_tools.upload_and_play(
        ch1,
        ch2,
        ip=args.ip,
        port=args.port,
        udp_interface=args.udp_interface,
        udp_source_ip=args.udp_source_ip,
        timeout_s=args.timeout_s,
        post_upload_sleep_s=args.post_upload_sleep_s,
        output_dir=args.output_dir,
        loop=args.loop,
        auto_start=not args.wait_for_trigger,
        ch3=ch3,
        ch4=ch4,
        channel_delays={
            channel: waveform_tools.delay_seconds_to_axis_cycles_by_freq(float(_channel_value(args, "delay_s", channel)), args.axis_freq_hz)
            for channel in range(1, 5)
        } if args.mode == "burst" else None,
    )
    print("Done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
