#!/usr/bin/env python3
"""Generate, save, upload, and play RFSoC DAC waveforms over UDP."""

import argparse
import sys
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import host  # noqa: E402
import waveform_tools  # noqa: E402


CHANNEL_DEFAULTS = {
    1: {"freq_hz": 20e6, "phase_rad": 0.0, "delay_s": 80e-9, "start": host.DDR_CH1_ADDR},
    2: {"freq_hz": 20e6, "phase_rad": np.pi / 2.0, "delay_s": 120e-9, "start": host.DDR_CH2_ADDR},
    3: {"freq_hz": 20e6, "phase_rad": 0.0, "delay_s": 160e-9, "start": host.DDR_CH3_ADDR},
    4: {"freq_hz": 20e6, "phase_rad": np.pi / 2.0, "delay_s": 200e-9, "start": host.DDR_CH4_ADDR},
    5: {"freq_hz": 20e6, "phase_rad": 0.0, "delay_s": 240e-9, "start": host.DDR_CH5_ADDR},
    6: {"freq_hz": 20e6, "phase_rad": np.pi / 2.0, "delay_s": 280e-9, "start": host.DDR_CH6_ADDR},
    7: {"freq_hz": 20e6, "phase_rad": 0.0, "delay_s": 320e-9, "start": host.DDR_CH7_ADDR},
    8: {"freq_hz": 20e6, "phase_rad": np.pi / 2.0, "delay_s": 360e-9, "start": host.DDR_CH8_ADDR},
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


def add_channel_sine_args(parser: argparse.ArgumentParser) -> None:
    for channel in range(1, 9):
        defaults = CHANNEL_DEFAULTS[channel]
        parser.add_argument(f"--ch{channel}-freq-hz", type=float, default=defaults["freq_hz"], help=f"CH{channel} sine frequency")
        parser.add_argument(f"--ch{channel}-phase-rad", type=float, default=defaults["phase_rad"], help=f"CH{channel} phase in radians")
    parser.add_argument("--x-freq-hz", type=float, default=None, help="Legacy alias for --ch1-freq-hz")
    parser.add_argument("--y-freq-hz", type=float, default=None, help="Legacy alias for --ch2-freq-hz")
    parser.add_argument("--x-phase-rad", type=float, default=None, help="Legacy alias for --ch1-phase-rad")
    parser.add_argument("--y-phase-rad", type=float, default=None, help="Legacy alias for --ch2-phase-rad")


def add_channel_burst_args(parser: argparse.ArgumentParser) -> None:
    for channel in range(1, 9):
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


def add_channel_golden_args(parser: argparse.ArgumentParser) -> None:
    for channel in range(1, 9):
        parser.add_argument(f"--ch{channel}-start", type=int, default=CHANNEL_DEFAULTS[channel]["start"])
    parser.add_argument("--x-start", type=int, default=None, help="Legacy alias for --ch1-start")
    parser.add_argument("--y-start", type=int, default=None, help="Legacy alias for --ch2-start")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="mode", required=True)

    sine = subparsers.add_parser("sine", help="continuous I/Q sine wave on CH1-CH8 for RFDC C2R")
    add_common_args(sine)
    add_channel_sine_args(sine)
    sine.add_argument("--amplitude", type=int, default=20000, help="DAC code amplitude, 0..32767")
    sine.add_argument("--encoding", choices=["signed"], default="signed")

    burst = subparsers.add_parser("burst", help="Gaussian-windowed RF bursts on CH1-CH8")
    add_common_args(burst)
    add_channel_burst_args(burst)
    burst.add_argument("--duration-s", type=float, default=120e-9, help="Gaussian burst duration")
    burst.add_argument("--amplitude", type=int, default=24000, help="DAC code amplitude, 0..32767")

    pypulse = subparsers.add_parser("pypulse", help="PyPulse-style XY/Z/readout I/Q tile buffers on CH1-CH8")
    add_common_args(pypulse)
    pypulse.add_argument("--xy-freq-hz", type=float, default=80e6, help="XY carrier frequency")
    pypulse.add_argument("--z-freq-hz", type=float, default=0.0, help="Z envelope nominal frequency metadata")
    pypulse.add_argument("--readout-freq-hz", type=float, default=120e6, help="Readout carrier frequency")
    pypulse.add_argument("--phase-rad", type=float, default=0.0, help="XY/readout I/Q phase")
    pypulse.add_argument("--duration-s", type=float, default=120e-9, help="Pulse envelope duration")
    pypulse.add_argument("--amplitude", type=int, default=24000, help="DAC code amplitude, 0..32767")

    golden = subparsers.add_parser("golden", help="incrementing int16 pattern for ILA/debug")
    add_common_args(golden)
    add_channel_golden_args(golden)

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


def generate_waveforms(args: argparse.Namespace) -> tuple[np.ndarray, ...]:
    if args.mode == "sine":
        waves = tuple(
            waveform_tools.make_iq_sine_tile_waveform(
                float(_channel_value(args, "freq_hz", channel)) * host.RFDC_INTERPOLATION,
                float(_channel_value(args, "phase_rad", channel)),
                args.amplitude,
                args.sample_rate_hz,
            )
            for channel in range(1, 9)
        )
        metadata = waveform_tools.build_metadata(
            mode="iq-sine",
            sample_rate_hz=args.sample_rate_hz,
            encoding="signed-iq-interleaved",
            loop=args.loop,
            amplitude=args.amplitude,
            **{_channel_key(channel, "freq_hz"): float(_channel_value(args, "freq_hz", channel)) for channel in range(1, 9)},
            **{_channel_key(channel, "phase_rad"): float(_channel_value(args, "phase_rad", channel)) for channel in range(1, 9)},
        )
        return (*waves, metadata)

    if args.mode == "burst":
        waves = tuple(
            waveform_tools.make_gaussian_burst(
                float(_channel_value(args, "freq_hz", channel)),
                float(_channel_value(args, "phase_rad", channel)),
                args.amplitude,
                args.sample_rate_hz,
                args.duration_s,
            )
            for channel in range(1, 9)
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
            **{_channel_key(channel, "freq_hz"): float(_channel_value(args, "freq_hz", channel)) for channel in range(1, 9)},
            **{_channel_key(channel, "phase_rad"): float(_channel_value(args, "phase_rad", channel)) for channel in range(1, 9)},
            **{_channel_key(channel, "delay_s"): float(_channel_value(args, "delay_s", channel)) for channel in range(1, 9)},
            **{
                _channel_key(channel, "delay_cycles"): waveform_tools.delay_seconds_to_axis_cycles_by_freq(
                    float(_channel_value(args, "delay_s", channel)), args.axis_freq_hz
                )
                for channel in range(1, 9)
            },
        )
        return (*waves, metadata)

    if args.mode == "pypulse":
        return waveform_tools.make_pypulse_waveform_bundle(
            sample_rate_hz=args.sample_rate_hz,
            loop=args.loop,
            amplitude=args.amplitude,
            duration_s=args.duration_s,
            xy_freq_hz=args.xy_freq_hz,
            z_freq_hz=args.z_freq_hz,
            readout_freq_hz=args.readout_freq_hz,
            phase_rad=args.phase_rad,
        )

    if args.mode == "golden":
        waves = tuple(
            waveform_tools.make_incrementing_pattern(start=int(_channel_value(args, "start", channel)))
            for channel in range(1, 9)
        )
        metadata = waveform_tools.build_metadata(
            mode="golden",
            sample_rate_hz=args.sample_rate_hz,
            encoding="uint16-viewed-as-int16",
            loop=args.loop,
            **{_channel_key(channel, "start"): int(_channel_value(args, "start", channel)) for channel in range(1, 9)},
        )
        return (*waves, metadata)

    raise ValueError(f"Unsupported waveform mode: {args.mode}")


def main() -> int:
    args = build_parser().parse_args()
    generated = generate_waveforms(args)
    *waves, metadata = generated
    extra_waves = {channel: wave for channel, wave in enumerate(waves[2:], start=3)}
    waveform_tools.save_waveform_bundle(
        args.output_dir,
        waves[0],
        waves[1],
        metadata,
        stem=args.mode,
        **{f"ch{channel}": wave for channel, wave in extra_waves.items() if channel <= 4},
        extra_channels={channel: wave for channel, wave in extra_waves.items() if channel > 4},
    )

    print(f"[waveform] mode={args.mode} sample_rate_hz={args.sample_rate_hz}")
    for channel, wave in enumerate(waves, start=1):
        print(f"[waveform] CH{channel} min={int(wave.min())} max={int(wave.max())} first16={wave[:16].tolist()}")
    print(f"[waveform] output_dir={args.output_dir}")
    if args.dry_run:
        print("[waveform] dry-run: not sending UDP packets")
        return 0

    waveform_tools.upload_and_play(
        waves[0],
        waves[1],
        ip=args.ip,
        port=args.port,
        udp_interface=args.udp_interface,
        udp_source_ip=args.udp_source_ip,
        timeout_s=args.timeout_s,
        post_upload_sleep_s=args.post_upload_sleep_s,
        output_dir=args.output_dir,
        loop=args.loop,
        auto_start=not args.wait_for_trigger,
        ch3=waves[2] if len(waves) > 2 else None,
        ch4=waves[3] if len(waves) > 3 else None,
        extra_channels={channel: wave for channel, wave in enumerate(waves[4:], start=5)},
        channel_delays={
            channel: waveform_tools.delay_seconds_to_axis_cycles_by_freq(float(_channel_value(args, "delay_s", channel)), args.axis_freq_hz)
            for channel in range(1, 9)
        } if args.mode == "burst" else None,
    )
    print("Done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
