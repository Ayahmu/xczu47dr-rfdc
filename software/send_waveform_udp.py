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


def parse_byte_count(value: str) -> int:
    text = str(value).strip().lower()
    if text == "max":
        return host.DDR_MAX_BYTES_PER_CHANNEL
    scales = {
        "kib": 1024,
        "mib": 1024**2,
        "gib": 1024**3,
        "kb": 1000,
        "mb": 1000**2,
        "gb": 1000**3,
    }
    for suffix, scale in scales.items():
        if text.endswith(suffix):
            return int(float(text[:-len(suffix)]) * scale)
    return int(text, 0)


def parse_u32(value: str) -> int:
    return int(value, 0) & 0xFFFFFFFF


def parse_mmio_write(value: str) -> tuple[int, int]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("MMIO batch write must be ADDR=VALUE")
    addr_s, value_s = value.split("=", 1)
    return parse_u32(addr_s), parse_u32(value_s)


def parse_channel_assignment(value: str, parser) -> tuple[int, object]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("channel assignment must be CH=VALUE")
    channel_s, value_s = value.split("=", 1)
    channel_text = channel_s.strip().lower()
    if channel_text.startswith("ch"):
        channel_text = channel_text[2:]
    try:
        channel = int(channel_text, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid channel {channel_s!r}") from exc
    if channel < 1 or channel > host.RFDC_CTRL_MAILBOX_CHANNELS:
        raise argparse.ArgumentTypeError(f"channel must be 1..{host.RFDC_CTRL_MAILBOX_CHANNELS}, got {channel}")
    return channel, parser(value_s)


def parse_nco_assignment(value: str) -> tuple[int, float]:
    return parse_channel_assignment(value, float)


def parse_zone_assignment(value: str) -> tuple[int, int]:
    channel, zone = parse_channel_assignment(value, lambda text: int(text, 0))
    if zone not in (1, 2):
        raise argparse.ArgumentTypeError(f"nyquist zone must be 1 or 2, got {zone}")
    return channel, zone


def add_rvctrl1_response_args(parser: argparse.ArgumentParser, default: bool = False) -> None:
    if default:
        parser.add_argument("--no-wait-response", dest="wait_response", action="store_false", help="Do not wait for RVRESP1")
        parser.set_defaults(wait_response=True)
    else:
        parser.add_argument("--wait-response", action="store_true", help="Wait for RVRESP1 and print the parsed reply")


def print_rvresp1(resp: dict[str, object]) -> None:
    payload = bytes(resp.get("payload", b""))
    print(
        f"[rvresp1] opcode=0x{int(resp['opcode']):08X} seq={int(resp['seq'])} "
        f"status=0x{int(resp['status']):04X} payload_bytes={int(resp['payload_bytes'])}"
    )
    if payload:
        print(f"[rvresp1] payload={payload.hex()}")
    if int(resp["opcode"]) == host.RV1_OP_MMIO_READ32 and len(payload) >= 8:
        addr = int.from_bytes(payload[0:4], "little")
        value = int.from_bytes(payload[4:8], "little")
        print(f"[rvresp1] mmio[0x{addr:08X}] = 0x{value:08X}")
    elif int(resp["opcode"]) in (host.RV1_OP_RFDC_CH_ENABLE, host.RV1_OP_RFDC_SET_NCO) and len(payload) >= 8:
        field0 = int.from_bytes(payload[0:4], "little")
        field1 = int.from_bytes(payload[4:8], "little")
        print(f"[rvresp1] ack_payload[0]=0x{field0:08X} ack_payload[1]=0x{field1:08X}")


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
    parser.add_argument("--loop", action="store_true", help="Replay the uploaded waveform continuously")
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

    max_length = subparsers.add_parser("max-length", help="stream a deterministic 8-channel record up to the usable DDR limit")
    add_common_args(max_length)
    max_length.add_argument(
        "--bytes-per-channel",
        type=parse_byte_count,
        default=host.DDR_MAX_BYTES_PER_CHANNEL,
        help="Logical bytes per channel; accepts max, integer, KiB, MiB, or GiB",
    )
    max_length.add_argument("--beats-per-datagram", type=int, default=128, help="512-bit DDR beats in each bulk UDP datagram")
    max_length.add_argument("--batch-pause-us", type=float, default=0.0, help="Optional pacing delay after each bulk UDP datagram")
    max_length.add_argument("--marker-bytes-per-channel", type=int, default=4096, help="Per-channel size of start/middle/end marker regions")
    max_length.add_argument(
        "--pattern",
        choices=[host.MAX_LENGTH_PATTERN_CW_MARKER, host.MAX_LENGTH_PATTERN_LOWFREQ_SINE],
        default=host.MAX_LENGTH_PATTERN_LOWFREQ_SINE,
        help="Streaming max-length payload pattern",
    )
    max_length.add_argument("--sine-freq-hz", type=float, default=10.0, help="Low-frequency sine rate used by --pattern lowfreq-sine")
    max_length.add_argument("--sine-amplitude", type=int, default=4096, help="Low-frequency sine I-code amplitude")
    max_length.add_argument("--waveform-cache-dir", default="", help="Directory for pre-generated max-length waveform payload files")
    max_length.add_argument("--no-waveform-cache", action="store_true", help="Generate max-length payload in memory while sending")
    max_length.add_argument("--force-waveform-cache", action="store_true", help="Regenerate the waveform cache before sending")
    max_length.add_argument("--generate-cache-only", action="store_true", help="Generate/reuse the waveform cache and exit without uploading")
    max_length.add_argument("--no-full-dump", action="store_true", help="Compatibility option; max-length mode never writes a full hex dump")

    rv_ping = subparsers.add_parser("rvctrl-ping", help="send one RVCTRL0 PING command to the PL control CPU path")
    add_common_args(rv_ping)
    rv_ping.add_argument("--seq", type=int, default=1)

    rv_play = subparsers.add_parser("rvctrl-play", help="send RVCTRL0 PLAY_INTERLEAVED; waveform data must already be in DDR")
    add_common_args(rv_play)
    rv_play.add_argument("--seq", type=int, default=1)
    rv_play.add_argument("--bytes-per-channel", type=parse_byte_count, default=host.FIXED_DATA_BYTES)
    rv_play.add_argument("--auto-start", action="store_true", help="Commit END as auto-start instead of waiting for trigger")

    rv_trigger = subparsers.add_parser("rvctrl-trigger", help="send one RVCTRL0 TRIGGER command")
    add_common_args(rv_trigger)
    rv_trigger.add_argument("--seq", type=int, default=1)

    rv1_ping = subparsers.add_parser("rvctrl1-ping", help="send one RVCTRL1 PING command")
    add_common_args(rv1_ping)
    rv1_ping.add_argument("--seq", type=int, default=1)
    add_rvctrl1_response_args(rv1_ping)

    rv1_play = subparsers.add_parser("rvctrl1-play", help="send RVCTRL1 PLAY_INTERLEAVED; waveform data must already be in DDR")
    add_common_args(rv1_play)
    rv1_play.add_argument("--seq", type=int, default=1)
    rv1_play.add_argument("--bytes-per-channel", type=parse_byte_count, default=host.FIXED_DATA_BYTES)
    rv1_play.add_argument("--auto-start", action="store_true", help="Commit END as auto-start instead of waiting for trigger")
    add_rvctrl1_response_args(rv1_play)

    rv1_trigger = subparsers.add_parser("rvctrl1-trigger", help="send one RVCTRL1 TRIGGER command")
    add_common_args(rv1_trigger)
    rv1_trigger.add_argument("--seq", type=int, default=1)
    add_rvctrl1_response_args(rv1_trigger)

    rv1_read = subparsers.add_parser("rvctrl1-mmio-read", help="send RVCTRL1 MMIO_READ32 command")
    add_common_args(rv1_read)
    rv1_read.add_argument("--seq", type=int, default=1)
    rv1_read.add_argument("--addr", type=parse_u32, required=True)
    add_rvctrl1_response_args(rv1_read, default=True)

    rv1_write = subparsers.add_parser("rvctrl1-mmio-write", help="send RVCTRL1 MMIO_WRITE32 command")
    add_common_args(rv1_write)
    rv1_write.add_argument("--seq", type=int, default=1)
    rv1_write.add_argument("--addr", type=parse_u32, required=True)
    rv1_write.add_argument("--value", type=parse_u32, required=True)
    add_rvctrl1_response_args(rv1_write)

    rv1_rmw = subparsers.add_parser("rvctrl1-mmio-rmw", help="send RVCTRL1 MMIO_RMW32 command")
    add_common_args(rv1_rmw)
    rv1_rmw.add_argument("--seq", type=int, default=1)
    rv1_rmw.add_argument("--addr", type=parse_u32, required=True)
    rv1_rmw.add_argument("--mask", type=parse_u32, required=True)
    rv1_rmw.add_argument("--value", type=parse_u32, required=True)
    add_rvctrl1_response_args(rv1_rmw)

    rv1_batch = subparsers.add_parser("rvctrl1-mmio-batch", help="send RVCTRL1 MMIO_BATCH write sequence")
    add_common_args(rv1_batch)
    rv1_batch.add_argument("--seq", type=int, default=1)
    rv1_batch.add_argument("--write", type=parse_mmio_write, action="append", required=True, help="ADDR=VALUE, may be repeated")
    add_rvctrl1_response_args(rv1_batch)

    rv1_status = subparsers.add_parser("rvctrl1-status", help="send RVCTRL1 STATUS_READ command and wait for RVRESP1")
    add_common_args(rv1_status)
    rv1_status.add_argument("--seq", type=int, default=1)
    add_rvctrl1_response_args(rv1_status, default=True)

    rv1_ch_enable = subparsers.add_parser("rvctrl1-rfdc-ch-enable", help="send RVCTRL1 RFDC_CH_ENABLE command")
    add_common_args(rv1_ch_enable)
    rv1_ch_enable.add_argument("--seq", type=int, default=1)
    rv1_ch_enable.add_argument("--channel-mask", type=parse_u32, required=True, help="8-bit mask of RFDC channels to update")
    rv1_ch_enable.add_argument("--enable-mask", type=parse_u32, required=True, help="8-bit enabled-channel value")
    add_rvctrl1_response_args(rv1_ch_enable)

    rv1_set_nco = subparsers.add_parser("rvctrl1-rfdc-set-nco", help="send RVCTRL1 RFDC_SET_NCO command")
    add_common_args(rv1_set_nco)
    rv1_set_nco.add_argument("--seq", type=int, default=1)
    rv1_set_nco.add_argument("--apply-mask", type=parse_u32, default=0xFF, help="8-bit mask of channels whose NCO settings should apply")
    rv1_set_nco.add_argument("--nco", type=parse_nco_assignment, action="append", default=[], help="CH=HZ, e.g. 1=100e6 or ch7=-1.9e9; may be repeated")
    rv1_set_nco.add_argument("--zone", type=parse_zone_assignment, action="append", default=[], help="CH=ZONE, zone is 1 or 2; may be repeated")
    add_rvctrl1_response_args(rv1_set_nco)

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
            loop=args.loop,
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


def max_length_metadata(args: argparse.Namespace) -> dict[str, object]:
    bytes_per_channel = int(args.bytes_per_channel)
    if bytes_per_channel <= 0 or bytes_per_channel > host.DDR_MAX_BYTES_PER_CHANNEL:
        raise ValueError(
            f"bytes_per_channel must be in [32, {host.DDR_MAX_BYTES_PER_CHANNEL}], got {bytes_per_channel}"
        )
    host.require_beat_aligned(bytes_per_channel, "bytes_per_channel")
    total_bytes = bytes_per_channel * host.DDR_INTERLEAVED_CHANNELS
    return {
        "mode": "max-length",
        "layout": host.DDR_LAYOUT_INTERLEAVED_512B,
        "pattern": args.pattern,
        "ddr_phys_bytes": host.DDR_PHYS_BYTES,
        "ddr_reserved_top_bytes": host.DDR_RESERVED_TOP_BYTES,
        "ddr_usable_waveform_bytes": host.DDR_USABLE_WAVEFORM_BYTES,
        "rfdc_mailbox_offset": host.RFDC_CTRL_MAILBOX_OFFSET,
        "bytes_per_channel": bytes_per_channel,
        "physical_ddr_bytes": total_bytes,
        "complex_samples_per_channel": bytes_per_channel // 4,
        "expected_rfdc_beats_per_channel": bytes_per_channel // host.BEAT_BYTES,
        "expected_datamover_beats": total_bytes // host.DDR_INTERLEAVED_BEAT_BYTES,
        "expected_duration_s": bytes_per_channel / (host.DAC_AXIS_HZ * host.BEAT_BYTES),
        "axis_hz": host.DAC_AXIS_HZ,
        "bytes_per_axis_beat": host.BEAT_BYTES,
        "marker_bytes_per_channel": int(args.marker_bytes_per_channel),
        "sine_freq_hz": float(args.sine_freq_hz),
        "sine_amplitude": int(args.sine_amplitude),
        "beats_per_datagram": int(args.beats_per_datagram),
        "use_waveform_cache": not bool(args.no_waveform_cache),
        "force_waveform_cache": bool(args.force_waveform_cache),
        "waveform_cache_dir": args.waveform_cache_dir,
        "loop": False,
        "wait_for_trigger": bool(args.wait_for_trigger),
    }


def run_max_length(args: argparse.Namespace) -> int:
    if args.ddr_layout != host.DDR_LAYOUT_INTERLEAVED_512B:
        raise ValueError("max-length mode requires ddr-layout=interleaved_512b")
    if args.loop:
        raise ValueError("max-length mode is a single-shot measurement and does not support --loop")
    metadata = max_length_metadata(args)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    metadata_path = output_dir / "max_length_metadata.json"
    metadata_path.write_text(json.dumps(metadata, indent=2, sort_keys=True), encoding="utf-8")
    print(
        f"[max-length] per_channel={metadata['bytes_per_channel']} bytes, "
        f"total={metadata['physical_ddr_bytes']} bytes, "
        f"duration={float(metadata['expected_duration_s']):.9f}s"
    )
    print(f"[max-length] metadata={metadata_path}")
    cache_dir = Path(args.waveform_cache_dir).expanduser() if args.waveform_cache_dir else output_dir / "waveform_cache"
    if args.dry_run and not args.generate_cache_only:
        return 0
    if not args.no_waveform_cache:
        cache_path = host.ensure_max_length_waveform_cache(
            cache_dir,
            int(metadata["bytes_per_channel"]),
            marker_bytes_per_channel=int(args.marker_bytes_per_channel),
            pattern=args.pattern,
            sine_freq_hz=float(args.sine_freq_hz),
            sine_amplitude=int(args.sine_amplitude),
            force=bool(args.force_waveform_cache),
        )
        print(f"[max-length] waveform cache={cache_path}")
        if args.generate_cache_only:
            return 0

    ctrl = host.RFSocController(
        args.ip,
        port=args.port,
        timeout_s=args.timeout_s,
        transport="udp",
        udp_interface=args.udp_interface,
        udp_source_ip=args.udp_source_ip,
    )
    try:
        datagrams = ctrl.upload_max_length_udp(
            int(metadata["bytes_per_channel"]),
            base_addr=host.DDR_BASE,
            beats_per_datagram=int(args.beats_per_datagram),
            marker_bytes_per_channel=int(args.marker_bytes_per_channel),
            pattern=args.pattern,
            sine_freq_hz=float(args.sine_freq_hz),
            sine_amplitude=int(args.sine_amplitude),
            batch_pause_s=max(0.0, float(args.batch_pause_us)) * 1e-6,
            use_waveform_cache=not bool(args.no_waveform_cache),
            waveform_cache_dir=cache_dir,
            force_waveform_cache=False,
        )
        print(f"[max-length] upload complete, datagrams={datagrams}")
        if args.post_upload_sleep_s > 0:
            time.sleep(args.post_upload_sleep_s)
        lengths = {channel: int(metadata["bytes_per_channel"]) for channel in range(1, 9)}
        ctrl.send_instructions(
            waveform_tools.build_play_commands(
                loop=False,
                auto_start=not args.wait_for_trigger,
                channel_lengths=lengths,
                channel_delays={channel: 0 for channel in range(1, 9)},
                layout=host.DDR_LAYOUT_INTERLEAVED_512B,
            )
        )
        print("[max-length] PLAY instructions sent")
        return 0
    finally:
        ctrl.close()


def main() -> int:
    args = build_parser().parse_args()
    rvctrl1_modes = {
        "rvctrl1-ping",
        "rvctrl1-play",
        "rvctrl1-trigger",
        "rvctrl1-mmio-read",
        "rvctrl1-mmio-write",
        "rvctrl1-mmio-rmw",
        "rvctrl1-mmio-batch",
        "rvctrl1-status",
        "rvctrl1-rfdc-ch-enable",
        "rvctrl1-rfdc-set-nco",
    }
    if args.mode in ("rvctrl-ping", "rvctrl-play", "rvctrl-trigger") or args.mode in rvctrl1_modes:
        if args.dry_run:
            if args.mode == "rvctrl-ping":
                packet = host.pack_rvctrl_ping(args.seq)
            elif args.mode == "rvctrl-play":
                packet = host.pack_rvctrl_play_interleaved(
                    args.bytes_per_channel,
                    seq=args.seq,
                    auto_start=bool(args.auto_start),
                    loop=bool(args.loop),
                )
            elif args.mode == "rvctrl-trigger":
                packet = host.pack_rvctrl_trigger(args.seq)
            elif args.mode == "rvctrl1-ping":
                packet = host.pack_rvctrl1_ping(args.seq)
            elif args.mode == "rvctrl1-play":
                packet = host.pack_rvctrl1_play_interleaved(
                    args.bytes_per_channel,
                    seq=args.seq,
                    auto_start=bool(args.auto_start),
                    loop=bool(args.loop),
                )
            elif args.mode == "rvctrl1-trigger":
                packet = host.pack_rvctrl1_trigger(args.seq)
            elif args.mode == "rvctrl1-mmio-read":
                packet = host.pack_rvctrl1_mmio_read32(args.addr, seq=args.seq)
            elif args.mode == "rvctrl1-mmio-write":
                packet = host.pack_rvctrl1_mmio_write32(args.addr, args.value, seq=args.seq)
            elif args.mode == "rvctrl1-mmio-rmw":
                packet = host.pack_rvctrl1_mmio_rmw32(args.addr, args.mask, args.value, seq=args.seq)
            elif args.mode == "rvctrl1-mmio-batch":
                packet = host.pack_rvctrl1_mmio_batch(args.write, seq=args.seq)
            elif args.mode == "rvctrl1-status":
                packet = host.pack_rvctrl1_status_read(seq=args.seq)
            elif args.mode == "rvctrl1-rfdc-ch-enable":
                packet = host.pack_rvctrl1_rfdc_ch_enable(args.channel_mask, args.enable_mask, seq=args.seq)
            else:
                nco = dict(args.nco)
                zones = dict(args.zone)
                packet = host.pack_rvctrl1_rfdc_set_nco(nco, zones, seq=args.seq, apply_mask=args.apply_mask)
            print(f"[rvctrl] dry-run mode={args.mode} bytes={len(packet)} hex={packet.hex()}")
            return 0

        ctrl = host.RFSocController(
            args.ip,
            port=args.port,
            timeout_s=args.timeout_s,
            transport="udp",
            udp_interface=args.udp_interface,
            udp_source_ip=args.udp_source_ip,
        )
        try:
            if args.mode == "rvctrl-ping":
                ctrl.rvctrl_ping(args.seq)
            elif args.mode == "rvctrl-play":
                ctrl.rvctrl_play_interleaved(
                    args.bytes_per_channel,
                    seq=args.seq,
                    auto_start=bool(args.auto_start),
                    loop=bool(args.loop),
                )
            elif args.mode == "rvctrl-trigger":
                ctrl.rvctrl_trigger(args.seq)
            elif args.mode == "rvctrl1-ping":
                resp = ctrl.rvctrl1_ping(args.seq, wait_response=bool(args.wait_response))
                if bool(args.wait_response):
                    print_rvresp1(resp)
            elif args.mode == "rvctrl1-play":
                resp = ctrl.rvctrl1_play_interleaved(
                    args.bytes_per_channel,
                    seq=args.seq,
                    auto_start=bool(args.auto_start),
                    loop=bool(args.loop),
                    wait_response=bool(args.wait_response),
                )
                if bool(args.wait_response):
                    print_rvresp1(resp)
            elif args.mode == "rvctrl1-trigger":
                resp = ctrl.rvctrl1_trigger(args.seq, wait_response=bool(args.wait_response))
                if bool(args.wait_response):
                    print_rvresp1(resp)
            elif args.mode == "rvctrl1-mmio-read":
                resp = ctrl.rvctrl1_mmio_read32(args.addr, seq=args.seq, wait_response=bool(args.wait_response))
                if bool(args.wait_response):
                    print_rvresp1(resp)
            elif args.mode == "rvctrl1-mmio-write":
                resp = ctrl.rvctrl1_mmio_write32(args.addr, args.value, seq=args.seq, wait_response=bool(args.wait_response))
                if bool(args.wait_response):
                    print_rvresp1(resp)
            elif args.mode == "rvctrl1-mmio-rmw":
                resp = ctrl.rvctrl1_mmio_rmw32(args.addr, args.mask, args.value, seq=args.seq, wait_response=bool(args.wait_response))
                if bool(args.wait_response):
                    print_rvresp1(resp)
            elif args.mode == "rvctrl1-mmio-batch":
                resp = ctrl.rvctrl1_mmio_batch(args.write, seq=args.seq, wait_response=bool(args.wait_response))
                if bool(args.wait_response):
                    print_rvresp1(resp)
            elif args.mode == "rvctrl1-status":
                resp = ctrl.rvctrl1_status_read(seq=args.seq, wait_response=bool(args.wait_response))
                if bool(args.wait_response):
                    print_rvresp1(resp)
            elif args.mode == "rvctrl1-rfdc-ch-enable":
                resp = ctrl.rvctrl1_rfdc_ch_enable(
                    args.channel_mask,
                    args.enable_mask,
                    seq=args.seq,
                    wait_response=bool(args.wait_response),
                )
                if bool(args.wait_response):
                    print_rvresp1(resp)
            else:
                resp = ctrl.rvctrl1_rfdc_set_nco(
                    dict(args.nco),
                    dict(args.zone),
                    seq=args.seq,
                    apply_mask=args.apply_mask,
                    wait_response=bool(args.wait_response),
                )
                if bool(args.wait_response):
                    print_rvresp1(resp)
            return 0
        finally:
            ctrl.close()

    if args.mode == "max-length":
        return run_max_length(args)
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
                    loop=args.loop or bool(metadata.get("loop", False)),
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
        loop=args.loop,
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
