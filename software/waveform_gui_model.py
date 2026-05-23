#!/usr/bin/env python3
"""Display-free model and controller helpers for the RFSoC waveform GUI."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
import socket
from typing import Callable

import numpy as np
from scipy.signal.windows import gaussian

import host
import waveform_tools


Uploader = Callable[..., None]
ConnectionProbeSender = Callable[["ConnectionConfig", bytes], int]
CONNECTION_TEST_PAYLOAD = b"RFSOC_GUI_TEST"


@dataclass(slots=True)
class ConnectionConfig:
    ip: str = host.DEFAULT_BOARD_IP
    port: int = host.DEFAULT_BOARD_PORT
    udp_interface: str = host.DEFAULT_UDP_INTERFACE or "enp225s0f0"
    udp_source_ip: str = host.DEFAULT_UDP_SOURCE_IP or "192.168.1.10"
    timeout_s: float = 5.0
    post_upload_sleep_s: float = 0.5


@dataclass(slots=True)
class ChannelWaveformConfig:
    waveform_type: str = "sine"
    quantum_gate: str = "x"
    rotation_angle_rad: float = np.pi
    virtual_z_phase_rad: float = 0.0
    freq_hz: float = 20e6
    phase_rad: float = 0.0
    amplitude: int = 20000
    encoding: str = "signed"
    delay_s: float = 80e-9
    duration_s: float = 120e-9
    pulse_preset: str = "x"
    pulse_sigma_s: float = 20e-9
    pulse_center_s: float = 80e-9
    start: int = 0


@dataclass(slots=True)
class WaveformConfig:
    mode: str = "sine"
    output_dir: Path = Path("/tmp/opencode/rfsoc_waveform_gui")
    sample_rate_hz: float = host.DAC_XY_FS
    loop: bool = False
    wait_for_trigger: bool = False
    dry_run: bool = True
    ch1_freq_hz: float = 80e6
    ch2_freq_hz: float = 120e6
    ch1_phase_rad: float = 0.0
    ch2_phase_rad: float = 0.0
    ch1_delay_s: float = 80e-9
    ch2_delay_s: float = 120e-9
    ch1_start: int = 0
    ch2_start: int = 0x1000
    x_freq_hz: float = 80e6
    y_freq_hz: float = 120e6
    x_phase_rad: float = 0.0
    y_phase_rad: float = 0.0
    amplitude: int = 24000
    encoding: str = "signed"
    x_delay_s: float = 80e-9
    y_delay_s: float = 120e-9
    duration_s: float = 120e-9
    pulse_preset: str = "x"
    pulse_sigma_s: float = 20e-9
    pulse_center_s: float = 80e-9
    x_start: int = 0
    y_start: int = 0x1000
    ch1: ChannelWaveformConfig | None = None
    ch2: ChannelWaveformConfig | None = None
    ch3: ChannelWaveformConfig | None = None
    ch4: ChannelWaveformConfig | None = None


@dataclass(slots=True)
class GeneratedWaveforms:
    ch1: np.ndarray
    ch2: np.ndarray
    metadata: dict
    ch3: np.ndarray = field(default_factory=lambda: np.zeros(host.NUM_SAMPLES, dtype=np.int16))
    ch4: np.ndarray = field(default_factory=lambda: np.zeros(host.NUM_SAMPLES, dtype=np.int16))

    @property
    def x(self) -> np.ndarray:
        return self.ch1

    @property
    def y(self) -> np.ndarray:
        return self.ch2

    def channel_items(self) -> tuple[tuple[str, np.ndarray], ...]:
        return (("CH1", self.ch1), ("CH2", self.ch2), ("CH3", self.ch3), ("CH4", self.ch4))


@dataclass(slots=True)
class ControllerResult:
    generated: GeneratedWaveforms
    output_dir: Path
    dry_run: bool
    log_lines: list[str] = field(default_factory=list)


@dataclass(slots=True)
class ConnectionTestResult:
    ok: bool
    message: str


CHANNEL_LABELS = {
    "ch1": "CH1 / DDR 0x0 / DAC20",
    "ch2": "CH2 / DDR 0x1000 / DAC22",
    "ch3": "CH3 / DDR 0x2000 / DAC30",
    "ch4": "CH4 / DDR 0x3000 / DAC32",
}

CHANNEL_UPLOAD_ARGS = {
    "ch1": "x",
    "ch2": "y",
    "ch3": "ch3",
    "ch4": "ch4",
}


def generate_waveforms(config: WaveformConfig) -> GeneratedWaveforms:
    if any(channel is not None for channel in (config.ch1, config.ch2, config.ch3, config.ch4)):
        return _generate_independent_waveforms(config)

    mode = config.mode.lower()
    if mode == "pulse":
        x, y, ch1_semantics, ch2_semantics = _make_pulse_preset(config)
        metadata = waveform_tools.build_metadata(
            mode="pulse",
            sample_rate_hz=config.sample_rate_hz,
            encoding="signed",
            loop=config.loop,
            pulse_preset=config.pulse_preset.lower(),
            pulse_sigma_s=config.pulse_sigma_s,
            pulse_center_s=config.pulse_center_s,
            amplitude=config.amplitude,
            ch1_label=CHANNEL_LABELS["ch1"],
            ch2_label=CHANNEL_LABELS["ch2"],
            ch3_label=CHANNEL_LABELS["ch3"],
            ch4_label=CHANNEL_LABELS["ch4"],
            ch1_semantics=ch1_semantics,
            ch2_semantics=ch2_semantics,
        )
        return GeneratedWaveforms(ch1=x, ch2=y, metadata=metadata)

    if mode == "sine":
        x = waveform_tools.make_sine(
            config.x_freq_hz,
            config.x_phase_rad,
            config.amplitude,
            config.sample_rate_hz,
            encoding=config.encoding,
        )
        y = waveform_tools.make_sine(
            config.y_freq_hz,
            config.y_phase_rad,
            config.amplitude,
            config.sample_rate_hz,
            encoding=config.encoding,
        )
        metadata = waveform_tools.build_metadata(
            mode="sine",
            sample_rate_hz=config.sample_rate_hz,
            encoding=config.encoding,
            loop=config.loop,
            ch1_freq_hz=config.x_freq_hz,
            ch2_freq_hz=config.y_freq_hz,
            ch1_phase_rad=config.x_phase_rad,
            ch2_phase_rad=config.y_phase_rad,
            amplitude=config.amplitude,
        )
        return GeneratedWaveforms(ch1=x, ch2=y, metadata=metadata)

    if mode == "burst":
        x = waveform_tools.make_gaussian_burst(
            config.x_freq_hz,
            config.x_phase_rad,
            config.amplitude,
            config.sample_rate_hz,
            config.duration_s,
            config.x_delay_s,
        )
        y = waveform_tools.make_gaussian_burst(
            config.y_freq_hz,
            config.y_phase_rad,
            config.amplitude,
            config.sample_rate_hz,
            config.duration_s,
            config.y_delay_s,
        )
        if not np.any(x) or not np.any(y):
            raise ValueError("burst mode produced all-zero samples; check duration, delay, amplitude, and sample rate")
        metadata = waveform_tools.build_metadata(
            mode="burst",
            sample_rate_hz=config.sample_rate_hz,
            encoding="signed",
            loop=config.loop,
            ch1_freq_hz=config.x_freq_hz,
            ch2_freq_hz=config.y_freq_hz,
            ch1_phase_rad=config.x_phase_rad,
            ch2_phase_rad=config.y_phase_rad,
            ch1_delay_s=config.x_delay_s,
            ch2_delay_s=config.y_delay_s,
            duration_s=config.duration_s,
            amplitude=config.amplitude,
        )
        return GeneratedWaveforms(ch1=x, ch2=y, metadata=metadata)

    if mode == "golden":
        x = waveform_tools.make_incrementing_pattern(start=config.x_start)
        y = waveform_tools.make_incrementing_pattern(start=config.y_start)
        metadata = waveform_tools.build_metadata(
            mode="golden",
            sample_rate_hz=config.sample_rate_hz,
            encoding="uint16-viewed-as-int16",
            loop=config.loop,
            ch1_start=config.x_start,
            ch2_start=config.y_start,
        )
        return GeneratedWaveforms(ch1=x, ch2=y, metadata=metadata)

    raise ValueError(f"Unsupported waveform mode: {config.mode}")


def _generate_independent_waveforms(config: WaveformConfig) -> GeneratedWaveforms:
    ch1_config = config.ch1 or ChannelWaveformConfig(waveform_type="off")
    ch2_config = config.ch2 or ChannelWaveformConfig(waveform_type="off")
    ch3_config = config.ch3 or ChannelWaveformConfig(waveform_type="off")
    ch4_config = config.ch4 or ChannelWaveformConfig(waveform_type="off")
    x = _make_channel_waveform(ch1_config, config.sample_rate_hz, "ch1")
    y = _make_channel_waveform(ch2_config, config.sample_rate_hz, "ch2")
    ch3 = _make_channel_waveform(ch3_config, config.sample_rate_hz, "ch3")
    ch4 = _make_channel_waveform(ch4_config, config.sample_rate_hz, "ch4")
    metadata = waveform_tools.build_metadata(
        mode="per-channel",
        sample_rate_hz=config.sample_rate_hz,
        encoding="mixed-per-channel",
        loop=config.loop,
        ch1_label=CHANNEL_LABELS["ch1"],
        ch2_label=CHANNEL_LABELS["ch2"],
        ch3_label=CHANNEL_LABELS["ch3"],
        ch4_label=CHANNEL_LABELS["ch4"],
        ch1=_channel_metadata(ch1_config, "ch1"),
        ch2=_channel_metadata(ch2_config, "ch2"),
        ch3=_channel_metadata(ch3_config, "ch3"),
        ch4=_channel_metadata(ch4_config, "ch4"),
    )
    return GeneratedWaveforms(ch1=x, ch2=y, ch3=ch3, ch4=ch4, metadata=metadata)


def _make_channel_waveform(config: ChannelWaveformConfig, sample_rate_hz: float, channel_name: str) -> np.ndarray:
    waveform_type = config.waveform_type.lower()
    if waveform_type == "off":
        return np.zeros(host.NUM_SAMPLES, dtype=np.int16)
    if waveform_type == "pulse":
        return _make_channel_pulse(config, sample_rate_hz, channel_name)
    if waveform_type == "quantum":
        return _make_quantum_gate_waveform(config, sample_rate_hz, channel_name)
    if waveform_type == "sine":
        return waveform_tools.make_sine(
            config.freq_hz,
            config.phase_rad,
            config.amplitude,
            sample_rate_hz,
            encoding=config.encoding,
        )
    if waveform_type == "burst":
        wave = waveform_tools.make_gaussian_burst(
            config.freq_hz,
            config.phase_rad,
            config.amplitude,
            sample_rate_hz,
            config.duration_s,
            config.delay_s,
        )
        if not np.any(wave):
            raise ValueError(f"{channel_name} burst produced all-zero samples; check duration, delay, amplitude, and sample rate")
        return wave
    if waveform_type == "golden":
        return waveform_tools.make_incrementing_pattern(start=config.start)
    raise ValueError(f"Unsupported {channel_name} waveform type: {config.waveform_type}")


def _make_channel_pulse(config: ChannelWaveformConfig, sample_rate_hz: float, channel_name: str) -> np.ndarray:
    pulse = _channel_gaussian_burst(config, sample_rate_hz)
    preset = config.pulse_preset.lower()
    if preset in ("x", "y"):
        return pulse
    if preset == "z":
        if channel_name == "ch1":
            return pulse
        return (-pulse).astype(np.int16)
    raise ValueError("pulse preset must be one of: x, y, z")


def _make_quantum_gate_waveform(config: ChannelWaveformConfig, sample_rate_hz: float, channel_name: str) -> np.ndarray:
    gate = config.quantum_gate.lower()
    if gate == "x":
        pulse = _channel_gaussian_burst(config, sample_rate_hz)
        return pulse if channel_name == "ch1" else np.zeros(host.NUM_SAMPLES, dtype=np.int16)
    if gate == "y":
        pulse = _channel_gaussian_burst(config, sample_rate_hz, phase_offset_rad=np.pi / 2.0)
        return pulse if channel_name == "ch2" else np.zeros(host.NUM_SAMPLES, dtype=np.int16)
    if gate == "z":
        pulse = _channel_gaussian_window_pulse(config, sample_rate_hz)
        if channel_name == "ch1":
            return pulse
        return (-pulse).astype(np.int16)
    raise ValueError("quantum gate must be one of: x, y, z")


def _channel_gaussian_burst(config: ChannelWaveformConfig, sample_rate_hz: float, phase_offset_rad: float = 0.0) -> np.ndarray:
    wave = waveform_tools.make_gaussian_burst(
        config.freq_hz,
        config.phase_rad + phase_offset_rad,
        config.amplitude,
        sample_rate_hz,
        config.duration_s,
        config.delay_s,
    )
    if not np.any(wave):
        raise ValueError("Gaussian burst produced all-zero samples; check duration, delay, amplitude, and sample rate")
    return wave


def _channel_gaussian_window_pulse(config: ChannelWaveformConfig, sample_rate_hz: float) -> np.ndarray:
    wave = np.zeros(host.NUM_SAMPLES, dtype=np.int16)
    start = max(0, int(round(config.delay_s * sample_rate_hz)))
    length = max(1, int(round(config.duration_s * sample_rate_hz)))
    end = min(host.NUM_SAMPLES, start + length)
    active = end - start
    if active <= 0:
        raise ValueError("Gaussian Z pulse has no active samples; check duration, delay, and sample rate")
    window = gaussian(active, std=max(active / 6.0, 1.0), sym=True)
    wave[start:end] = np.round(np.clip(window * float(config.amplitude), -32767.0, 32767.0)).astype(np.int16)
    if not np.any(wave):
        raise ValueError("Gaussian Z pulse produced all-zero samples; check duration, delay, amplitude, and sample rate")
    return wave


def _channel_metadata(config: ChannelWaveformConfig, channel: str) -> dict:
    return {
        "label": CHANNEL_LABELS[channel],
        "upload_arg": CHANNEL_UPLOAD_ARGS[channel],
        "type": config.waveform_type.lower(),
        "quantum_gate": config.quantum_gate.lower(),
        "rotation_angle_rad": config.rotation_angle_rad,
        "virtual_z_phase_rad": config.virtual_z_phase_rad,
        "semantics": _channel_semantics(config),
        "pulse_backend": _pulse_backend(config),
        "freq_hz": config.freq_hz,
        "phase_rad": config.phase_rad,
        "amplitude": config.amplitude,
        "encoding": config.encoding,
        "delay_s": config.delay_s,
        "duration_s": config.duration_s,
        "pulse_preset": config.pulse_preset,
        "pulse_sigma_s": config.pulse_sigma_s,
        "pulse_center_s": config.pulse_center_s,
        "start": config.start,
    }


def _channel_semantics(config: ChannelWaveformConfig) -> str:
    if config.waveform_type.lower() != "quantum":
        return "hardware waveform"
    gate = config.quantum_gate.lower()
    if gate == "x":
        return "X rotation drive on I quadrature"
    if gate == "y":
        return "Y rotation drive with +90 degree quadrature phase"
    if gate == "z":
        return "Z detuning-style phase pulse on DAC pair"
    return "unknown quantum operation"


def _pulse_backend(config: ChannelWaveformConfig) -> str:
    if config.waveform_type.lower() == "quantum":
        return "scipy"
    return "internal"


def _gaussian_envelope(config: WaveformConfig) -> np.ndarray:
    n = np.arange(host.NUM_SAMPLES, dtype=np.float64)
    t = n / float(config.sample_rate_hz)
    sigma = float(config.pulse_sigma_s)
    if sigma <= 0.0:
        raise ValueError("pulse sigma must be positive")
    envelope = np.exp(-0.5 * ((t - float(config.pulse_center_s)) / sigma) ** 2)
    return np.round(np.clip(envelope * float(config.amplitude), -32767.0, 32767.0)).astype(np.int16)


def _make_pulse_preset(config: WaveformConfig) -> tuple[np.ndarray, np.ndarray, str, str]:
    pulse = _gaussian_envelope(config)
    zeros = np.zeros(host.NUM_SAMPLES, dtype=np.int16)
    preset = config.pulse_preset.lower()
    if preset == "x":
        return pulse, zeros, "X pulse", "off"
    if preset == "y":
        return zeros, pulse, "off", "Y pulse"
    if preset == "z":
        return pulse, (-pulse).astype(np.int16), "Z pulse positive", "Z pulse negative"
    raise ValueError("pulse preset must be one of: x, y, z")


def summarize_waveform(name: str, wave: np.ndarray) -> str:
    return f"{name}: min={int(wave.min())} max={int(wave.max())} first16={wave[:16].tolist()}"


def build_send_summary(config: WaveformConfig, connection: ConnectionConfig) -> str:
    ch1 = config.ch1 or ChannelWaveformConfig(waveform_type=config.mode)
    ch2 = config.ch2 or ChannelWaveformConfig(waveform_type=config.mode)
    ch3 = config.ch3 or ChannelWaveformConfig(waveform_type="off")
    ch4 = config.ch4 or ChannelWaveformConfig(waveform_type="off")
    auto_start = "no, wait for trigger" if config.wait_for_trigger else "yes"
    return "\n".join(
        [
            f"Target: {connection.ip}:{connection.port}",
            f"UDP interface: {connection.udp_interface or '(default route)'}",
            f"Source IP: {connection.udp_source_ip or '(auto)'}",
            f"Sample rate: {config.sample_rate_hz:g} Hz",
            f"Loop playback: {'yes' if config.loop else 'no'}",
            f"Auto start: {auto_start}",
            f"Output dir: {Path(config.output_dir)}",
            f"{CHANNEL_LABELS['ch1']}: {_summarize_channel(ch1)}",
            f"{CHANNEL_LABELS['ch2']}: {_summarize_channel(ch2)}",
            f"{CHANNEL_LABELS['ch3']}: {_summarize_channel(ch3)}",
            f"{CHANNEL_LABELS['ch4']}: {_summarize_channel(ch4)}",
        ]
    )


def _summarize_channel(config: ChannelWaveformConfig) -> str:
    waveform_type = config.waveform_type.lower()
    if waveform_type == "quantum":
        return f"quantum {config.quantum_gate.lower()}"
    if waveform_type == "sine":
        return f"sine {config.freq_hz:g} Hz"
    if waveform_type == "burst":
        return f"burst {config.freq_hz:g} Hz delay={config.delay_s:g}s duration={config.duration_s:g}s"
    if waveform_type == "pulse":
        return f"pulse {config.pulse_preset.lower()}"
    if waveform_type == "golden":
        return f"golden start={config.start:#x}"
    return waveform_type


def _udp_probe_sender(connection: ConnectionConfig, payload: bytes) -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(connection.timeout_s)
        if connection.udp_interface:
            sock.setsockopt(socket.SOL_SOCKET, host.SO_BINDTODEVICE, connection.udp_interface.encode("ascii") + b"\0")
        if connection.udp_source_ip:
            sock.bind((connection.udp_source_ip, 0))
        return sock.sendto(payload, (connection.ip, connection.port))


def test_connection(connection: ConnectionConfig, sender: ConnectionProbeSender = _udp_probe_sender) -> ConnectionTestResult:
    try:
        byte_count = sender(connection, CONNECTION_TEST_PAYLOAD)
    except OSError as exc:
        return ConnectionTestResult(ok=False, message=f"connection test failed: {exc}")
    return ConnectionTestResult(ok=True, message=f"connection test sent {byte_count} bytes to {connection.ip}:{connection.port}")


def preview_series(wave: np.ndarray, max_points: int = 512) -> tuple[np.ndarray, np.ndarray]:
    step = max(1, int(np.ceil(len(wave) / max_points)))
    indices = np.arange(0, len(wave), step, dtype=np.int32)
    return indices, wave[indices]


class WaveformController:
    def __init__(self, uploader: Uploader = waveform_tools.upload_and_play):
        self.uploader = uploader

    def run(self, config: WaveformConfig, connection: ConnectionConfig) -> ControllerResult:
        generated = generate_waveforms(config)
        output_dir = Path(config.output_dir)
        waveform_tools.save_waveform_bundle(
            output_dir,
            generated.x,
            generated.y,
            generated.metadata,
            stem=config.mode,
            ch3=generated.ch3,
            ch4=generated.ch4,
        )

        log_lines = [
            "progress: generated waveforms",
            f"mode={config.mode} sample_rate_hz={config.sample_rate_hz:g}",
            summarize_waveform("X", generated.x),
            summarize_waveform("Y", generated.y),
            summarize_waveform("CH3", generated.ch3),
            summarize_waveform("CH4", generated.ch4),
            "progress: saved artifacts",
            f"saved artifacts to {output_dir}",
        ]
        if config.dry_run:
            log_lines.append("dry-run: not sending UDP packets")
            log_lines.append("progress: dry-run complete")
            return ControllerResult(generated=generated, output_dir=output_dir, dry_run=True, log_lines=log_lines)

        log_lines.append("progress: sending UDP packets")
        self.uploader(
            generated.x,
            generated.y,
            ip=connection.ip,
            port=connection.port,
            udp_interface=connection.udp_interface,
            udp_source_ip=connection.udp_source_ip,
            timeout_s=connection.timeout_s,
            post_upload_sleep_s=connection.post_upload_sleep_s,
            output_dir=output_dir,
            loop=config.loop,
            auto_start=not config.wait_for_trigger,
            ch3=generated.ch3,
            ch4=generated.ch4,
        )
        log_lines.append("progress: send complete")
        log_lines.append(f"sent UDP waveform to {connection.ip}:{connection.port}")
        return ControllerResult(generated=generated, output_dir=output_dir, dry_run=False, log_lines=log_lines)
