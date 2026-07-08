#!/usr/bin/env python3
"""Generate, save, upload, and play RFSoC DAC waveforms over UDP."""

import argparse
import json
import sys
from pathlib import Path
import time

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
    parser.add_argument("--sample-rate-hz", "--sample-rate", dest="sample_rate_hz", type=float, default=host.DAC_XY_FS, help="RFDC input I/Q sample rate used for waveform synthesis")
    parser.add_argument("--axis-freq-hz", type=float, default=host.DAC_AXIS_HZ, help="DAC AXIS clock used to convert hardware delay ns to cycles")
    parser.add_argument("--loop", action="store_true", help="Replay the uploaded waveform continuously for legacy debug modes")
    parser.add_argument("--wait-for-trigger", action="store_true", help="Do not auto-start; wait for PS/external trigger")
    parser.add_argument("--dry-run", action="store_true", help="Only generate local waveform files; do not send UDP packets")
    parser.add_argument(
        "--ddr-layout",
        choices=[host.DDR_LAYOUT_TILED, host.DDR_LAYOUT_CONTIGUOUS, host.DDR_LAYOUT_INTERLEAVED_512B],
        default=host.DEFAULT_DDR_LAYOUT,
        help="DDR upload/playback layout; interleaved_512b is the normal synchronous RFDC output chain",
    )


def add_ezq_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--artifact-dir", type=Path, required=True, help="Directory containing ez-Q compatible artifacts")
    parser.add_argument(
        "--wave-format",
        choices=["packed_iq", "iq_matrix", "interleaved_iq"],
        default="packed_iq",
        help="How to interpret the saved ez-Q wave artifact",
    )
    parser.add_argument("--channels", default="1,2,3,4,5,6,7,8", help="Comma-separated channel list to upload")


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

    sine = subparsers.add_parser("sine", help="finite-length I/Q sine wave on CH1-CH8 for RFDC C2R")
    add_common_args(sine)
    add_channel_sine_args(sine)
    sine.add_argument("--amplitude", type=int, default=20000, help="DAC code amplitude, 0..32767")
    sine.add_argument("--encoding", choices=["signed"], default="signed")
    sine.add_argument("--duration-s", type=float, default=1e-6, help="Finite I/Q record length in seconds")
    sine.add_argument("--zero-tail-s", type=float, default=50e-9, help="Zero I/Q tail appended after the finite sine record")

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

    ezq = subparsers.add_parser("ezq", help="upload ez-Q style wave/seq artifacts through the RFSoC 10G path")
    add_common_args(ezq)
    add_ezq_args(ezq)

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
        sample_count = waveform_tools.iq_duration_to_sample_count(args.duration_s, args.sample_rate_hz)
        waves = tuple(
            waveform_tools.append_iq_zero_tail(
                waveform_tools.make_iq_sine_tile_waveform(
                    float(_channel_value(args, "freq_hz", channel)),
                    float(_channel_value(args, "phase_rad", channel)),
                    args.amplitude,
                    args.sample_rate_hz,
                    sample_count=sample_count,
                ),
                args.zero_tail_s,
                args.sample_rate_hz,
            )
            for channel in range(1, 9)
        )
        metadata = waveform_tools.build_metadata(
            mode="iq-sine",
            sample_rate_hz=args.sample_rate_hz,
            encoding="signed-iq-interleaved",
            loop=False,
            layout=args.ddr_layout,
            amplitude=args.amplitude,
            duration_s=args.duration_s,
            zero_tail_s=args.zero_tail_s,
            **{_channel_key(channel, "freq_hz"): float(_channel_value(args, "freq_hz", channel)) for channel in range(1, 9)},
            **{_channel_key(channel, "phase_rad"): float(_channel_value(args, "phase_rad", channel)) for channel in range(1, 9)},
        )
        for channel, wave in enumerate(waves, start=1):
            metadata[f"ch{channel}_logical_bytes"] = waveform_tools.waveform_length_bytes(wave)
            metadata[f"ch{channel}_samples_per_channel"] = int(wave.size)
            metadata[f"ch{channel}_complex_samples"] = int(wave.size) // 2
            metadata[f"ch{channel}_record_duration_s"] = (int(wave.size) // 2) / float(args.sample_rate_hz)
        metadata["samples_per_channel"] = int(sample_count)
        metadata["bytes_per_channel"] = waveform_tools.waveform_length_bytes(waves[0])
        metadata["record_duration_s"] = (int(sample_count) // 2) / float(args.sample_rate_hz)
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
            layout=args.ddr_layout,
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
            layout=args.ddr_layout,
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
            layout=args.ddr_layout,
            **{_channel_key(channel, "start"): int(_channel_value(args, "start", channel)) for channel in range(1, 9)},
        )
        return (*waves, metadata)

    raise ValueError(f"Unsupported waveform mode: {args.mode}")


def _load_ezq_channel_artifacts(args: argparse.Namespace) -> tuple[dict[int, np.ndarray], dict[int, np.ndarray], dict[str, object]]:
    metadata_path = args.artifact_dir / "ezq_metadata.json"
    if not metadata_path.exists():
        raise FileNotFoundError(f"Missing ez-Q metadata file: {metadata_path}")
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    if not isinstance(metadata, dict):
        raise ValueError("ez-Q metadata must be a JSON object")

    requested_channels = {int(ch) for ch in args.channels.split(",") if ch.strip()}
    channel_waves: dict[int, np.ndarray] = {}
    channel_sequences: dict[int, np.ndarray] = {}
    for channel_info in metadata.get("channels", []):
        if not isinstance(channel_info, dict):
            continue
        channel = int(channel_info.get("channel", 0))
        if channel not in requested_channels:
            continue

        wave_file = channel_info.get("wave_packed_npy")
        seq_file = channel_info.get("seq_npy")
        if not wave_file:
            raise ValueError(f"Missing wave artifact file name for channel {channel}")

        wave_path = args.artifact_dir / str(wave_file)
        if not wave_path.exists():
            raise FileNotFoundError(f"Missing ez-Q wave artifact: {wave_path}")
        channel_waves[channel] = waveform_tools.load_ezq_channel_wave(wave_path, wave_format=args.wave_format)

        if seq_file:
            seq_path = args.artifact_dir / str(seq_file)
            if seq_path.exists():
                channel_sequences[channel] = waveform_tools.ezq_sequence_rows(np.load(seq_path, allow_pickle=False))

    if not channel_waves:
        raise ValueError("No ez-Q channel artifacts matched the requested channels")
    return channel_waves, channel_sequences, metadata


def main() -> int:
    args = build_parser().parse_args()
    if args.mode == "ezq":
        channel_waves, channel_sequences, metadata = _load_ezq_channel_artifacts(args)
        layout = str(metadata.get("layout", args.ddr_layout))
        if layout not in (host.DDR_LAYOUT_INTERLEAVED_512B, host.DDR_LAYOUT_TILED, host.DDR_LAYOUT_CONTIGUOUS):
            layout = args.ddr_layout

        output_dir = Path(args.output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        waveform_tools.save_ezq_wave_bundle(
            output_dir,
            channel_waves,
            metadata,
            channel_sequences=channel_sequences,
            channel_format="interleaved_iq",
            stem="ezq_upload",
        )

        print(f"[ezq] artifact_dir={args.artifact_dir}")
        print(f"[ezq] channels={sorted(channel_waves)} layout={layout}")
        if args.dry_run:
            print("[ezq] dry-run: not sending UDP packets")
            return 0

        channel_lengths = {channel: waveform_tools.waveform_length_bytes(samples) for channel, samples in channel_waves.items()}
        channel_delays = {
            channel: int(metadata.get(f"ch{channel}_delay_cycles", 0))
            for channel in channel_waves
        }
        if layout == host.DDR_LAYOUT_INTERLEAVED_512B:
            channel_delays = {channel: 0 for channel in channel_waves}

        ctrl = host.RFSocController(
            args.ip,
            port=args.port,
            timeout_s=args.timeout_s,
            transport="udp",
            udp_interface=args.udp_interface,
            udp_source_ip=args.udp_source_ip,
        )
        try:
            channel_addrs: dict[int, int] = {}
            if layout == host.DDR_LAYOUT_INTERLEAVED_512B:
                ctrl.upload_waveform_udp_interleaved(channel_waves, base_addr=host.DDR_BASE, dump_path=str(output_dir / "ezq_interleaved_upload_hex.txt"))
            else:
                channel_addrs = {
                    channel: (host.tiled_channel_base_addr(channel) if layout == host.DDR_LAYOUT_TILED else host.DDR_CH_ADDR[channel - 1])
                    for channel in sorted(channel_waves)
                }
                for channel, samples in sorted(channel_waves.items()):
                    dump = f"ch{channel}_ezq_upload_hex.txt"
                    if layout == host.DDR_LAYOUT_TILED:
                        ctrl.upload_waveform_udp_tiled(samples, channel=channel, base_addr=host.DDR_BASE, dump_path=str(output_dir / dump))
                    else:
                        ctrl.upload_waveform_udp(samples, channel_addrs[channel], str(output_dir / dump))
            if args.post_upload_sleep_s > 0:
                print(f"[ezq] waiting {args.post_upload_sleep_s:.3f}s for DDR write completion")
                time.sleep(args.post_upload_sleep_s)
            ctrl.send_instructions(
                waveform_tools.build_play_commands(
                    loop=bool(metadata.get("loop", False)),
                    auto_start=not args.wait_for_trigger,
                    channel_addrs=None if layout == host.DDR_LAYOUT_INTERLEAVED_512B else channel_addrs,
                    channel_lengths=channel_lengths,
                    channel_delays=channel_delays,
                    layout=layout,
                )
            )
            print("Done.")
            return 0
        finally:
            ctrl.close()

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
        loop=False if args.mode == "sine" else args.loop,
        auto_start=not args.wait_for_trigger,
        ch3=waves[2] if len(waves) > 2 else None,
        ch4=waves[3] if len(waves) > 3 else None,
        extra_channels={channel: wave for channel, wave in enumerate(waves[4:], start=5)},
        layout=args.ddr_layout,
        channel_delays={
            channel: waveform_tools.delay_seconds_to_axis_cycles_by_freq(float(_channel_value(args, "delay_s", channel)), args.axis_freq_hz)
            for channel in range(1, 9)
        } if args.mode == "burst" and args.ddr_layout != host.DDR_LAYOUT_INTERLEAVED_512B else None,
        rfdc_nco_hz=metadata.get("per_channel_nco") if isinstance(metadata.get("per_channel_nco"), dict) else None,
        rfdc_nyquist_zones=metadata.get("per_channel_zone") if isinstance(metadata.get("per_channel_zone"), dict) else None,
    )
    print("Done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
