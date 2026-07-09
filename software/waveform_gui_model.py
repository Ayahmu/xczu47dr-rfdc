#!/usr/bin/env python3
"""Display-free model and controller helpers for the RFSoC waveform GUI."""

from __future__ import annotations

from dataclasses import dataclass, field, replace
import json
import math
import os
from pathlib import Path
import socket
import subprocess
import sys
from typing import Any, Callable, TypedDict

import numpy as np
try:
    from scipy.signal.windows import gaussian
except ModuleNotFoundError:
    def gaussian(M: int, std: float, sym: bool = True) -> np.ndarray:
        if M < 1:
            return np.array([], dtype=np.float64)
        n = np.arange(0, M, dtype=np.float64) - (M - 1.0) / 2.0
        return np.exp(-0.5 * (n / float(std)) ** 2)

import host
import waveform_tools


Uploader = Callable[..., None]
ConnectionProbeSender = Callable[["ConnectionConfig", bytes], int]
IlaSubprocessRunner = Callable[[list[str]], subprocess.CompletedProcess[str]]
CONNECTION_TEST_PAYLOAD = b"RFSOC_GUI_TEST"
SOFTWARE_DIR = Path(__file__).resolve().parent
ILA_CAPTURE_REPORT_SCRIPT = SOFTWARE_DIR / "ila_capture_report.py"
DEFAULT_ILA_BIT_PATH = Path("hardware/vivado/output/custom_xczu47dr_rfdc.bit")
DEFAULT_ILA_LTX_PATH = Path("hardware/vivado/output/custom_xczu47dr_rfdc.ltx")
DEFAULT_ILA_REPORT_DIR = Path("software/ila_reports")
DEFAULT_GUI_SETTINGS_PATH = (
    Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    / "xczu47dr-waveform-gui"
    / "settings.json"
)


class MetadataBase(TypedDict):
    rfdc_interpolation: int
    analog_sample_rate_hz: float


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
    waveform_type: str = "iq-sine"
    pypulse_waveform: str = "xy"
    quantum_gate: str = "x"
    rotation_angle_rad: float = np.pi
    virtual_z_phase_rad: float = 0.0
    freq_hz: float = 20e6
    phase_rad: float = 0.0
    amplitude: int = 20000
    encoding: str = "signed"
    delay_s: float = 80e-9
    duration_s: float = 1e-6
    zero_tail_s: float = 50e-9
    pulse_preset: str = "x"
    pulse_sigma_s: float = 20e-9
    pulse_center_s: float = 80e-9
    start: int = 0


@dataclass(slots=True)
class EzqPulseConfig:
    qubit_name: str = "q1"
    f10_hz: float = 4.5e9
    f21_hz: float = 4.35e9
    fc_hz: float = 4.5e9
    uwave_power_dbm: float = 8.0
    uwave_phase_rad: float = 0.0
    nonlinearity_hz: float = -250e6
    pi_amp: float = 0.35
    pi_len_s: float = 120e-9
    pi_fwhm_s: float = 50e-9
    pi_alpha: float = 0.0
    pi_amp_half: float = 0.175
    pi_len_half_s: float = 60e-9
    pi_fwhm_half_s: float = 25e-9
    pi_alpha_half: float = 0.0
    pi_amp21: float = 0.5
    pi_amp21_half: float = 0.25
    pi_df_hz: float = 0.0
    xy_phase_rad: float = 0.0
    z_offset: float = 0.0
    pi_amp_z: float = 0.25
    pi_len_z_s: float = 240e-9
    z_shape: str = "square"
    z_start_s: float = 0.0
    z_gate_time_s: float = 200e-9
    z_edge_s: float = 5e-9
    z_ripple0: float = 0.0
    z_ripple1: float = 0.1
    z_ripple2: float = 0.0
    z_ripple3: float = 0.0
    readout_freq_hz: float = 5.8e9
    readout_fc_hz: float = 5.8e9
    readout_len_s: float = 1e-6
    readout_edge_s: float = 30e-9
    readout_flattop_s: float = 900e-9
    readout_zpa: float = 0.0
    readout_power_dbm: float = -20.0
    ring_power_dbm: float = -20.0
    readout_uwave_power_dbm: float = 18.0
    ring_len_s: float = 100e-9
    readout_start_s: float = 0.0
    spec_amp: float = 0.2
    spec_len_s: float = 1e-6
    adc_start_delay_s: float = 0.0
    timing_lag_xy_s: float = 0.0
    timing_lag_z_s: float = 0.0
    timing_lag_read_s: float = 0.0
    repeat: int = 1
    period_s: float = 10e-6
    record_duration_s: float = host.DEFAULT_RECORD_DURATION_S
    channel_mask: int = 0xFF
    ch1: "EzqChannelConfig | None" = None
    ch2: "EzqChannelConfig | None" = None
    ch3: "EzqChannelConfig | None" = None
    ch4: "EzqChannelConfig | None" = None
    ch5: "EzqChannelConfig | None" = None
    ch6: "EzqChannelConfig | None" = None
    ch7: "EzqChannelConfig | None" = None
    ch8: "EzqChannelConfig | None" = None


@dataclass(slots=True)
class EzqChannelConfig:
    enabled: bool = True
    waveform: str = "xy"
    xy_gate: str = "x_pi"
    target_rf_hz: float = 0.0
    detune_hz: float = 0.0
    start_time_s: float = 0.0
    f10_hz: float = 4.6e9
    f21_hz: float = 4.35e9
    fc_hz: float = 4.5e9
    nonlinearity_hz: float = -250e6
    pi_amp: float = 0.55
    pi_len_s: float = 60e-9
    pi_fwhm_s: float = 30e-9
    pi_alpha: float = 0.5
    pi_amp_half: float = 0.275
    pi_len_half_s: float = 30e-9
    pi_fwhm_half_s: float = 15e-9
    pi_alpha_half: float = 0.0
    pi_amp21: float = 0.5
    pi_amp21_half: float = 0.25
    pi_df_hz: float = 0.0
    xy_phase_rad: float = 0.0
    spec_amp: float = 0.2
    spec_len_s: float = 1e-6
    z_amp: float = 0.2
    z_len_s: float = 240e-9
    z_shape: str = "square"
    z_start_s: float = 0.0
    z_gate_time_s: float = 100e-9
    z_edge_s: float = 2e-9
    z_ripple0: float = 0.0
    z_ripple1: float = 0.1
    z_ripple2: float = 0.0
    z_ripple3: float = 0.0
    readout_freq_hz: float = 5.8e9
    readout_fc_hz: float = 5.8e9
    readout_amp: float = 0.5
    readout_len_s: float = 4e-6
    readout_start_s: float = 0.0
    readout_phase_rad: float = 0.0
    readout_edge_s: float = 30e-9
    readout_flattop_s: float = 4060e-9
    readout_zpa: float = 0.0
    timing_lag_xy_s: float = 0.0
    period_s: float = 1e-6


def default_test_ezq_config() -> EzqPulseConfig:
    """Board-test defaults for the current 8-channel RFDC role map."""

    xy_common = {
        "enabled": True,
        "waveform": "xy",
        "xy_gate": "x_pi",
        "target_rf_hz": 4.5e9,
        "f10_hz": 4.5e9,
        "f21_hz": 4.35e9,
        "fc_hz": 4.5e9,
        "nonlinearity_hz": -250e6,
        "pi_amp": 0.35,
        "pi_len_s": 120e-9,
        "pi_fwhm_s": 50e-9,
        "pi_alpha": 0.0,
        "period_s": host.DEFAULT_RECORD_DURATION_S,
    }
    readout_common = {
        "enabled": True,
        "waveform": "readout",
        "readout_amp": 0.25,
        "readout_len_s": 1e-6,
        "readout_start_s": 0.0,
        "readout_edge_s": 30e-9,
        "readout_flattop_s": 900e-9,
        "readout_zpa": 0.0,
        "period_s": host.DEFAULT_RECORD_DURATION_S,
    }
    z_common = {
        "enabled": True,
        "waveform": "z",
        "z_amp": 0.25,
        "z_len_s": 240e-9,
        "z_start_s": 0.0,
        "z_gate_time_s": 200e-9,
        "z_edge_s": 5e-9,
        "period_s": host.DEFAULT_RECORD_DURATION_S,
    }
    return EzqPulseConfig(
        f10_hz=4.5e9,
        f21_hz=4.35e9,
        fc_hz=4.5e9,
        nonlinearity_hz=-250e6,
        pi_amp=0.35,
        pi_len_s=120e-9,
        pi_fwhm_s=50e-9,
        pi_alpha=0.0,
        pi_amp_half=0.175,
        pi_len_half_s=60e-9,
        pi_fwhm_half_s=25e-9,
        pi_alpha_half=0.0,
        pi_df_hz=0.0,
        pi_amp_z=0.25,
        pi_len_z_s=240e-9,
        z_shape="square",
        z_start_s=0.0,
        z_gate_time_s=200e-9,
        z_edge_s=5e-9,
        readout_freq_hz=5.8e9,
        readout_fc_hz=5.8e9,
        readout_len_s=1e-6,
        readout_edge_s=30e-9,
        readout_flattop_s=900e-9,
        readout_zpa=0.0,
        repeat=1,
        period_s=host.DEFAULT_RECORD_DURATION_S,
        record_duration_s=host.DEFAULT_RECORD_DURATION_S,
        channel_mask=0xFF,
        ch1=EzqChannelConfig(**xy_common, detune_hz=0.0, start_time_s=100e-9, xy_phase_rad=0.0),
        ch2=EzqChannelConfig(**xy_common, detune_hz=10e6, start_time_s=250e-9, xy_phase_rad=np.pi / 2.0),
        ch3=EzqChannelConfig(**xy_common, detune_hz=-10e6, start_time_s=400e-9, xy_phase_rad=np.pi),
        ch4=EzqChannelConfig(**xy_common, detune_hz=40e6, start_time_s=550e-9, xy_phase_rad=3.0 * np.pi / 2.0),
        ch5=EzqChannelConfig(**z_common, z_shape="square", start_time_s=800e-9),
        ch6=EzqChannelConfig(**z_common, start_time_s=1_050e-9, z_shape="diabatic_cz"),
        ch7=EzqChannelConfig(**readout_common, target_rf_hz=5.8e9, readout_freq_hz=5.8e9, readout_fc_hz=5.8e9, start_time_s=1_400e-9),
        ch8=EzqChannelConfig(**readout_common, target_rf_hz=6.2e9, readout_freq_hz=6.2e9, readout_fc_hz=6.2e9, start_time_s=1_650e-9, readout_phase_rad=np.pi / 2.0),
    )


@dataclass(slots=True)
class WaveformConfig:
    mode: str = "ezq-quantum"
    ddr_layout: str = host.DEFAULT_DDR_LAYOUT
    output_dir: Path = Path("/tmp/opencode/rfsoc_waveform_gui")
    sample_rate_hz: float = host.DAC_XY_FS
    rfdc_interpolation: int = host.RFDC_INTERPOLATION
    axis_freq_hz: float = host.DAC_AXIS_HZ
    loop: bool = False
    wait_for_trigger: bool = False
    dry_run: bool = False
    ch1_freq_hz: float = 80e6
    ch2_freq_hz: float = 120e6
    ch1_phase_rad: float = 0.0
    ch2_phase_rad: float = 0.0
    ch1_delay_s: float = 80e-9
    ch2_delay_s: float = 120e-9
    ch1_start: int = host.DDR_CH1_ADDR
    ch2_start: int = host.DDR_CH2_ADDR
    x_freq_hz: float = 80e6
    y_freq_hz: float = 120e6
    x_phase_rad: float = 0.0
    y_phase_rad: float = 0.0
    amplitude: int = 24000
    encoding: str = "signed"
    x_delay_s: float = 80e-9
    y_delay_s: float = 120e-9
    duration_s: float = 1e-6
    zero_tail_s: float = 50e-9
    record_duration_s: float = host.DEFAULT_RECORD_DURATION_S
    pulse_preset: str = "x"
    pulse_sigma_s: float = 20e-9
    pulse_center_s: float = 80e-9
    x_start: int = host.DDR_CH1_ADDR
    y_start: int = host.DDR_CH2_ADDR
    ch1: ChannelWaveformConfig | None = None
    ch2: ChannelWaveformConfig | None = None
    ch3: ChannelWaveformConfig | None = None
    ch4: ChannelWaveformConfig | None = None
    ch5: ChannelWaveformConfig | None = None
    ch6: ChannelWaveformConfig | None = None
    ch7: ChannelWaveformConfig | None = None
    ch8: ChannelWaveformConfig | None = None
    ezq: EzqPulseConfig = field(default_factory=default_test_ezq_config)


@dataclass(slots=True)
class GeneratedWaveforms:
    ch1: np.ndarray
    ch2: np.ndarray
    metadata: dict
    ch3: np.ndarray = field(default_factory=lambda: np.zeros(host.NUM_SAMPLES, dtype=np.int16))
    ch4: np.ndarray = field(default_factory=lambda: np.zeros(host.NUM_SAMPLES, dtype=np.int16))
    ch5: np.ndarray = field(default_factory=lambda: np.zeros(host.NUM_SAMPLES, dtype=np.int16))
    ch6: np.ndarray = field(default_factory=lambda: np.zeros(host.NUM_SAMPLES, dtype=np.int16))
    ch7: np.ndarray = field(default_factory=lambda: np.zeros(host.NUM_SAMPLES, dtype=np.int16))
    ch8: np.ndarray = field(default_factory=lambda: np.zeros(host.NUM_SAMPLES, dtype=np.int16))

    @property
    def x(self) -> np.ndarray:
        return self.ch1

    @property
    def y(self) -> np.ndarray:
        return self.ch2

    def channel_items(self) -> tuple[tuple[str, np.ndarray], ...]:
        return (
            ("CH1", self.ch1),
            ("CH2", self.ch2),
            ("CH3", self.ch3),
            ("CH4", self.ch4),
            ("CH5", self.ch5),
            ("CH6", self.ch6),
            ("CH7", self.ch7),
            ("CH8", self.ch8),
        )


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


@dataclass(slots=True, init=False)
class IlaReportConfig:
    bitstream_path: Path
    ltx_path: Path
    output_dir: Path
    artifact_dir: Path
    program_mode: str

    def __init__(
        self,
        bitstream_path: Path | None = None,
        ltx_path: Path = DEFAULT_ILA_LTX_PATH,
        output_dir: Path | None = None,
        artifact_dir: Path = Path("/tmp/opencode/rfsoc_waveform_gui"),
        program_mode: str | None = None,
        bit_path: Path | None = None,
        report_dir: Path | None = None,
        program_fpga: bool | None = None,
    ) -> None:
        selected_program_mode = program_mode
        if selected_program_mode is None:
            selected_program_mode = "auto" if program_fpga else "never"
        if selected_program_mode not in {"ask", "auto", "always", "never"}:
            raise ValueError("program_mode must be one of: ask, auto, always, never")
        self.bitstream_path = bitstream_path or bit_path or DEFAULT_ILA_BIT_PATH
        self.ltx_path = ltx_path
        self.output_dir = output_dir or report_dir or DEFAULT_ILA_REPORT_DIR
        self.artifact_dir = artifact_dir
        self.program_mode = selected_program_mode

    @property
    def bit_path(self) -> Path:
        return self.bitstream_path

    @property
    def report_dir(self) -> Path:
        return self.output_dir

    @property
    def program_fpga(self) -> bool:
        return self.program_mode in {"auto", "always"}


@dataclass(slots=True)
class IlaReportResult:
    ok: bool
    returncode: int
    overall_status: str
    markdown_report: Path | None
    json_report: Path | None
    stdout: str
    stderr: str
    command: list[str]
    log_lines: list[str] = field(default_factory=list)


@dataclass(slots=True)
class GuiSettings:
    waveform: WaveformConfig = field(default_factory=WaveformConfig)
    connection: ConnectionConfig = field(default_factory=ConnectionConfig)
    ila: IlaReportConfig = field(default_factory=IlaReportConfig)


def _channel_config_to_dict(config: ChannelWaveformConfig | None) -> dict[str, object] | None:
    if config is None:
        return None
    return {
        "waveform_type": config.waveform_type,
        "pypulse_waveform": config.pypulse_waveform,
        "quantum_gate": config.quantum_gate,
        "rotation_angle_rad": config.rotation_angle_rad,
        "virtual_z_phase_rad": config.virtual_z_phase_rad,
        "freq_hz": config.freq_hz,
        "phase_rad": config.phase_rad,
        "amplitude": config.amplitude,
        "encoding": config.encoding,
        "delay_s": config.delay_s,
        "duration_s": config.duration_s,
        "zero_tail_s": config.zero_tail_s,
        "pulse_preset": config.pulse_preset,
        "pulse_sigma_s": config.pulse_sigma_s,
        "pulse_center_s": config.pulse_center_s,
        "start": config.start,
    }


def _channel_config_from_dict(data: object) -> ChannelWaveformConfig | None:
    if data is None:
        return None
    if not isinstance(data, dict):
        raise ValueError("channel settings must be a JSON object or null")
    allowed = {
        "waveform_type",
        "pypulse_waveform",
        "quantum_gate",
        "rotation_angle_rad",
        "virtual_z_phase_rad",
        "freq_hz",
        "phase_rad",
        "amplitude",
        "encoding",
        "delay_s",
        "duration_s",
        "zero_tail_s",
        "pulse_preset",
        "pulse_sigma_s",
        "pulse_center_s",
        "start",
    }
    kwargs = {key: value for key, value in data.items() if key in allowed}
    waveform_type = str(kwargs.get("waveform_type", "iq-sine")).lower()
    if waveform_type == "sine":
        kwargs["waveform_type"] = "iq-sine"
    elif waveform_type in {"pypulse", "burst", "hls", "iq-gaussian", "iq-gaussian-sine"}:
        kwargs["waveform_type"] = "iq-gaussian-sine"
    elif waveform_type == "off":
        kwargs["waveform_type"] = "off"
    elif waveform_type not in {"iq-sine", "dc-iq-cw", "iq-gaussian-sine"}:
        kwargs["waveform_type"] = "dc-iq-cw"
    return ChannelWaveformConfig(**kwargs)


def _ezq_config_to_dict(config: EzqPulseConfig) -> dict[str, object]:
    return {
        "qubit_name": config.qubit_name,
        "f10_hz": config.f10_hz,
        "f21_hz": config.f21_hz,
        "fc_hz": config.fc_hz,
        "uwave_power_dbm": config.uwave_power_dbm,
        "uwave_phase_rad": config.uwave_phase_rad,
        "nonlinearity_hz": config.nonlinearity_hz,
        "pi_amp": config.pi_amp,
        "pi_len_s": config.pi_len_s,
        "pi_fwhm_s": config.pi_fwhm_s,
        "pi_alpha": config.pi_alpha,
        "pi_amp_half": config.pi_amp_half,
        "pi_len_half_s": config.pi_len_half_s,
        "pi_fwhm_half_s": config.pi_fwhm_half_s,
        "pi_alpha_half": config.pi_alpha_half,
        "pi_amp21": config.pi_amp21,
        "pi_amp21_half": config.pi_amp21_half,
        "pi_df_hz": config.pi_df_hz,
        "xy_phase_rad": config.xy_phase_rad,
        "z_offset": config.z_offset,
        "pi_amp_z": config.pi_amp_z,
        "pi_len_z_s": config.pi_len_z_s,
        "z_shape": config.z_shape,
        "z_start_s": config.z_start_s,
        "z_gate_time_s": config.z_gate_time_s,
        "z_edge_s": config.z_edge_s,
        "z_ripple0": config.z_ripple0,
        "z_ripple1": config.z_ripple1,
        "z_ripple2": config.z_ripple2,
        "z_ripple3": config.z_ripple3,
        "readout_freq_hz": config.readout_freq_hz,
        "readout_fc_hz": config.readout_fc_hz,
        "readout_len_s": config.readout_len_s,
        "readout_edge_s": config.readout_edge_s,
        "readout_flattop_s": config.readout_flattop_s,
        "readout_zpa": config.readout_zpa,
        "readout_power_dbm": config.readout_power_dbm,
        "ring_power_dbm": config.ring_power_dbm,
        "readout_uwave_power_dbm": config.readout_uwave_power_dbm,
        "ring_len_s": config.ring_len_s,
        "readout_start_s": config.readout_start_s,
        "spec_amp": config.spec_amp,
        "spec_len_s": config.spec_len_s,
        "adc_start_delay_s": config.adc_start_delay_s,
        "timing_lag_xy_s": config.timing_lag_xy_s,
        "timing_lag_z_s": config.timing_lag_z_s,
        "timing_lag_read_s": config.timing_lag_read_s,
        "repeat": config.repeat,
        "period_s": config.period_s,
        "record_duration_s": config.record_duration_s,
        "channel_mask": config.channel_mask,
        "ch1": _ezq_channel_config_to_dict(config.ch1),
        "ch2": _ezq_channel_config_to_dict(config.ch2),
        "ch3": _ezq_channel_config_to_dict(config.ch3),
        "ch4": _ezq_channel_config_to_dict(config.ch4),
        "ch5": _ezq_channel_config_to_dict(config.ch5),
        "ch6": _ezq_channel_config_to_dict(config.ch6),
        "ch7": _ezq_channel_config_to_dict(config.ch7),
        "ch8": _ezq_channel_config_to_dict(config.ch8),
    }


def _ezq_channel_config_to_dict(config: EzqChannelConfig | None) -> dict[str, object] | None:
    if config is None:
        return None
    return {
        "enabled": config.enabled,
        "waveform": config.waveform,
        "xy_gate": config.xy_gate,
        "target_rf_hz": config.target_rf_hz,
        "detune_hz": config.detune_hz,
        "start_time_s": config.start_time_s,
        "f10_hz": config.f10_hz,
        "f21_hz": config.f21_hz,
        "fc_hz": config.fc_hz,
        "nonlinearity_hz": config.nonlinearity_hz,
        "pi_amp": config.pi_amp,
        "pi_len_s": config.pi_len_s,
        "pi_fwhm_s": config.pi_fwhm_s,
        "pi_alpha": config.pi_alpha,
        "pi_amp_half": config.pi_amp_half,
        "pi_len_half_s": config.pi_len_half_s,
        "pi_fwhm_half_s": config.pi_fwhm_half_s,
        "pi_alpha_half": config.pi_alpha_half,
        "pi_amp21": config.pi_amp21,
        "pi_amp21_half": config.pi_amp21_half,
        "pi_df_hz": config.pi_df_hz,
        "xy_phase_rad": config.xy_phase_rad,
        "spec_amp": config.spec_amp,
        "spec_len_s": config.spec_len_s,
        "z_amp": config.z_amp,
        "z_len_s": config.z_len_s,
        "z_shape": config.z_shape,
        "z_start_s": config.z_start_s,
        "z_gate_time_s": config.z_gate_time_s,
        "z_edge_s": config.z_edge_s,
        "z_ripple0": config.z_ripple0,
        "z_ripple1": config.z_ripple1,
        "z_ripple2": config.z_ripple2,
        "z_ripple3": config.z_ripple3,
        "readout_freq_hz": config.readout_freq_hz,
        "readout_fc_hz": config.readout_fc_hz,
        "readout_amp": config.readout_amp,
        "readout_len_s": config.readout_len_s,
        "readout_start_s": config.readout_start_s,
        "readout_phase_rad": config.readout_phase_rad,
        "readout_edge_s": config.readout_edge_s,
        "readout_flattop_s": config.readout_flattop_s,
        "readout_zpa": config.readout_zpa,
        "timing_lag_xy_s": config.timing_lag_xy_s,
        "period_s": config.period_s,
    }


def _ezq_channel_config_from_dict(data: object) -> EzqChannelConfig | None:
    if data is None:
        return None
    if not isinstance(data, dict):
        raise ValueError("ezq channel settings must be a JSON object or null")
    allowed = set(_ezq_channel_config_to_dict(EzqChannelConfig()) or {})
    kwargs = {key: value for key, value in data.items() if key in allowed}
    if "enabled" in kwargs:
        kwargs["enabled"] = bool(kwargs["enabled"])
    waveform = str(kwargs.get("waveform", "xy")).lower()
    if waveform not in {"xy", "z", "readout"}:
        waveform = "xy"
    kwargs["waveform"] = waveform
    z_shape = str(kwargs.get("z_shape", "square")).lower()
    if z_shape not in {"square", "diabatic_cz"}:
        z_shape = "square"
    kwargs["z_shape"] = z_shape
    xy_gate = str(kwargs.get("xy_gate", "x_pi")).lower()
    if xy_gate not in {"x_pi", "y_pi", "x_half", "y_half", "x12_pi", "x12_half", "spec"}:
        xy_gate = "x_pi"
    kwargs["xy_gate"] = xy_gate
    return EzqChannelConfig(**kwargs)


def _ezq_config_from_dict(data: object) -> EzqPulseConfig:
    if not isinstance(data, dict):
        return EzqPulseConfig()
    allowed = set(_ezq_config_to_dict(EzqPulseConfig()))
    kwargs = {key: value for key, value in data.items() if key in allowed}
    if "qubit_name" in kwargs:
        kwargs["qubit_name"] = str(kwargs["qubit_name"])
    if "z_shape" in kwargs:
        z_shape = str(kwargs["z_shape"]).lower()
        kwargs["z_shape"] = z_shape if z_shape in {"square", "diabatic_cz"} else "square"
    if "channel_mask" in kwargs:
        kwargs["channel_mask"] = int(kwargs["channel_mask"])
    if "repeat" in kwargs:
        kwargs["repeat"] = int(kwargs["repeat"])
    for channel in ("ch1", "ch2", "ch3", "ch4", "ch5", "ch6", "ch7", "ch8"):
        if channel in data:
            kwargs[channel] = _ezq_channel_config_from_dict(data[channel])
    return EzqPulseConfig(**kwargs)


def _waveform_config_to_dict(config: WaveformConfig) -> dict[str, object]:
    return {
        "mode": config.mode,
        "ddr_layout": config.ddr_layout,
        "output_dir": str(config.output_dir),
        "sample_rate_hz": config.sample_rate_hz,
        "rfdc_interpolation": config.rfdc_interpolation,
        "axis_freq_hz": config.axis_freq_hz,
        "loop": False,
        "wait_for_trigger": config.wait_for_trigger,
        "dry_run": config.dry_run,
        "ch1_freq_hz": config.ch1_freq_hz,
        "ch2_freq_hz": config.ch2_freq_hz,
        "ch1_phase_rad": config.ch1_phase_rad,
        "ch2_phase_rad": config.ch2_phase_rad,
        "ch1_delay_s": config.ch1_delay_s,
        "ch2_delay_s": config.ch2_delay_s,
        "ch1_start": config.ch1_start,
        "ch2_start": config.ch2_start,
        "x_freq_hz": config.x_freq_hz,
        "y_freq_hz": config.y_freq_hz,
        "x_phase_rad": config.x_phase_rad,
        "y_phase_rad": config.y_phase_rad,
        "amplitude": config.amplitude,
        "encoding": config.encoding,
        "x_delay_s": config.x_delay_s,
        "y_delay_s": config.y_delay_s,
        "duration_s": config.duration_s,
        "zero_tail_s": config.zero_tail_s,
        "record_duration_s": config.record_duration_s,
        "pulse_preset": config.pulse_preset,
        "pulse_sigma_s": config.pulse_sigma_s,
        "pulse_center_s": config.pulse_center_s,
        "x_start": config.x_start,
        "y_start": config.y_start,
        "ch1": _channel_config_to_dict(config.ch1),
        "ch2": _channel_config_to_dict(config.ch2),
        "ch3": _channel_config_to_dict(config.ch3),
        "ch4": _channel_config_to_dict(config.ch4),
        "ch5": _channel_config_to_dict(config.ch5),
        "ch6": _channel_config_to_dict(config.ch6),
        "ch7": _channel_config_to_dict(config.ch7),
        "ch8": _channel_config_to_dict(config.ch8),
        "ezq": _ezq_config_to_dict(config.ezq),
    }


def _waveform_config_from_dict(data: object) -> WaveformConfig:
    if not isinstance(data, dict):
        return WaveformConfig()
    allowed = {
        "mode",
        "ddr_layout",
        "sample_rate_hz",
        "rfdc_interpolation",
        "axis_freq_hz",
        "loop",
        "wait_for_trigger",
        "dry_run",
        "ch1_freq_hz",
        "ch2_freq_hz",
        "ch1_phase_rad",
        "ch2_phase_rad",
        "ch1_delay_s",
        "ch2_delay_s",
        "ch1_start",
        "ch2_start",
        "x_freq_hz",
        "y_freq_hz",
        "x_phase_rad",
        "y_phase_rad",
        "amplitude",
        "encoding",
        "x_delay_s",
        "y_delay_s",
        "duration_s",
        "zero_tail_s",
        "record_duration_s",
        "pulse_preset",
        "pulse_sigma_s",
        "pulse_center_s",
        "x_start",
        "y_start",
    }
    kwargs: dict[str, Any] = {key: value for key, value in data.items() if key in allowed}
    kwargs["loop"] = False
    saved_sample_rate = float(kwargs.get("sample_rate_hz", host.DAC_XY_FS))
    if saved_sample_rate in {float(host.DAC_TILE_FS), 9_600_000_000.0, 8_000_000_000.0, 6_000_000_000.0}:
        kwargs["sample_rate_hz"] = host.DAC_XY_FS
    if "output_dir" in data:
        kwargs["output_dir"] = Path(str(data["output_dir"]))
    for channel in ("ch1", "ch2", "ch3", "ch4", "ch5", "ch6", "ch7", "ch8"):
        if channel in data:
            kwargs[channel] = _channel_config_from_dict(data[channel])
    kwargs["ezq"] = _ezq_config_from_dict(data.get("ezq"))
    if kwargs.get("ddr_layout") not in {
        host.DDR_LAYOUT_CONTIGUOUS,
        host.DDR_LAYOUT_TILED,
        host.DDR_LAYOUT_INTERLEAVED_512B,
        None,
    }:
        kwargs["ddr_layout"] = host.DEFAULT_DDR_LAYOUT
    return WaveformConfig(**kwargs)


def _connection_config_to_dict(config: ConnectionConfig) -> dict[str, object]:
    return {
        "ip": config.ip,
        "port": config.port,
        "udp_interface": config.udp_interface,
        "udp_source_ip": config.udp_source_ip,
        "timeout_s": config.timeout_s,
        "post_upload_sleep_s": config.post_upload_sleep_s,
    }


def _connection_config_from_dict(data: object) -> ConnectionConfig:
    if not isinstance(data, dict):
        return ConnectionConfig()
    allowed = {"ip", "port", "udp_interface", "udp_source_ip", "timeout_s", "post_upload_sleep_s"}
    return ConnectionConfig(**{key: value for key, value in data.items() if key in allowed})


def _ila_config_to_dict(config: IlaReportConfig) -> dict[str, object]:
    return {
        "bitstream_path": str(config.bitstream_path),
        "ltx_path": str(config.ltx_path),
        "output_dir": str(config.output_dir),
        "artifact_dir": str(config.artifact_dir),
        "program_mode": config.program_mode,
    }


def _ila_config_from_dict(data: object, artifact_dir: Path) -> IlaReportConfig:
    if not isinstance(data, dict):
        return IlaReportConfig(artifact_dir=artifact_dir)
    return IlaReportConfig(
        bitstream_path=Path(str(data.get("bitstream_path", DEFAULT_ILA_BIT_PATH))),
        ltx_path=Path(str(data.get("ltx_path", DEFAULT_ILA_LTX_PATH))),
        output_dir=Path(str(data.get("output_dir", DEFAULT_ILA_REPORT_DIR))),
        artifact_dir=Path(str(data.get("artifact_dir", artifact_dir))),
        program_mode=str(data.get("program_mode", "never")),
    )


def gui_settings_to_dict(settings: GuiSettings) -> dict[str, object]:
    return {
        "version": 1,
        "waveform": _waveform_config_to_dict(settings.waveform),
        "connection": _connection_config_to_dict(settings.connection),
        "ila": _ila_config_to_dict(settings.ila),
    }


def gui_settings_from_dict(data: dict[str, object]) -> GuiSettings:
    waveform = _waveform_config_from_dict(data.get("waveform"))
    return GuiSettings(
        waveform=waveform,
        connection=_connection_config_from_dict(data.get("connection")),
        ila=_ila_config_from_dict(data.get("ila"), waveform.output_dir),
    )


def load_gui_settings(path: Path = DEFAULT_GUI_SETTINGS_PATH) -> GuiSettings:
    if not path.exists():
        return GuiSettings()
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("GUI settings file must contain a JSON object")
    return gui_settings_from_dict(data)


def save_gui_settings(settings: GuiSettings, path: Path = DEFAULT_GUI_SETTINGS_PATH) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(gui_settings_to_dict(settings), indent=2, sort_keys=True) + "\n", encoding="utf-8")


CHANNEL_LABELS = {
    "ch1": "CH1 / XY / lane0 / vout00",
    "ch2": "CH2 / XY / lane1 / vout02",
    "ch3": "CH3 / XY / lane2 / vout10",
    "ch4": "CH4 / XY / lane3 / vout12",
    "ch5": "CH5 / Z / lane4 / vout20",
    "ch6": "CH6 / Z / lane5 / vout22",
    "ch7": "CH7 / Readout / lane6 / vout30",
    "ch8": "CH8 / Readout / lane7 / vout32",
}

CHANNEL_UPLOAD_ARGS = {
    "ch1": "x",
    "ch2": "y",
    "ch3": "ch3",
    "ch4": "ch4",
    "ch5": "ch5",
    "ch6": "ch6",
    "ch7": "ch7",
    "ch8": "ch8",
}


def analog_sample_rate_hz(config: WaveformConfig) -> float:
    return float(config.sample_rate_hz) * int(config.rfdc_interpolation)


def python_frequency_hz(scope_freq_hz: float, rfdc_interpolation: int) -> float:
    # The generators already synthesize at the DAC sample rate configured in
    # `sample_rate_hz`, so the requested tone frequency is used directly.
    # Keep the helper name for existing call sites, but do not rescale by the
    # RFDC interpolation factor here.
    return float(scope_freq_hz)


def _validate_iq_frequency(freq_hz: float, sample_rate_hz: float, channel_name: str) -> None:
    nyquist_hz = float(sample_rate_hz) / 2.0
    if abs(float(freq_hz)) > nyquist_hz:
        raise ValueError(
            f"{channel_name} IQ frequency {float(freq_hz) / 1e6:g} MHz exceeds "
            f"the RFDC input Nyquist limit {nyquist_hz / 1e6:g} MHz. "
            "Use the RFDC NCO for the RF center frequency and set the GUI "
            "frequency to the baseband offset."
        )


def _metadata_base(config: WaveformConfig) -> MetadataBase:
    return {
        "rfdc_interpolation": int(config.rfdc_interpolation),
        "analog_sample_rate_hz": analog_sample_rate_hz(config),
    }


def _has_independent_channel_configs(config: WaveformConfig) -> bool:
    return any(getattr(config, channel) is not None for channel in ("ch1", "ch2", "ch3", "ch4", "ch5", "ch6", "ch7", "ch8"))


def generate_waveforms(config: WaveformConfig) -> GeneratedWaveforms:
    has_channel_configs = _has_independent_channel_configs(config)
    if config.mode.lower() == "ezq-quantum" and not has_channel_configs:
        return _generate_ezq_quantum_waveforms(config)
    if has_channel_configs:
        return _generate_independent_waveforms(config)

    mode = config.mode.lower()
    if mode == "pulse":
        x, y, ch1_semantics, ch2_semantics = _make_pulse_preset(config)
        metadata = waveform_tools.build_metadata(
            mode="pulse",
            sample_rate_hz=config.sample_rate_hz,
            encoding="signed",
            loop=config.loop,
            layout=config.ddr_layout,
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
            **_metadata_base(config),
        )
        return GeneratedWaveforms(ch1=x, ch2=y, metadata=metadata)

    if mode in ("sine", "iq-sine"):
        x_python_freq_hz = python_frequency_hz(config.x_freq_hz, config.rfdc_interpolation)
        y_python_freq_hz = python_frequency_hz(config.y_freq_hz, config.rfdc_interpolation)
        sample_count = waveform_tools.iq_duration_to_sample_count(config.duration_s, config.sample_rate_hz)
        x = waveform_tools.make_iq_sine_tile_waveform(
            x_python_freq_hz,
            config.x_phase_rad,
            config.amplitude,
            config.sample_rate_hz,
            sample_count=sample_count,
            q_sign=-1,
        )
        x = waveform_tools.append_iq_zero_tail(x, config.zero_tail_s, config.sample_rate_hz)
        y = waveform_tools.make_iq_sine_tile_waveform(
            y_python_freq_hz,
            config.y_phase_rad,
            config.amplitude,
            config.sample_rate_hz,
            sample_count=sample_count,
            q_sign=-1,
        )
        y = waveform_tools.append_iq_zero_tail(y, config.zero_tail_s, config.sample_rate_hz)
        metadata = waveform_tools.build_metadata(
            mode=mode,
            sample_rate_hz=config.sample_rate_hz,
            encoding="signed-iq-interleaved",
            loop=False,
            layout=config.ddr_layout,
            ch1_freq_hz=config.x_freq_hz,
            ch2_freq_hz=config.y_freq_hz,
            ch1_phase_rad=config.x_phase_rad,
            ch2_phase_rad=config.y_phase_rad,
            amplitude=config.amplitude,
            ch1_scope_freq_hz=config.x_freq_hz,
            ch2_scope_freq_hz=config.y_freq_hz,
            ch1_python_freq_hz=x_python_freq_hz,
            ch2_python_freq_hz=y_python_freq_hz,
            duration_s=config.duration_s,
            zero_tail_s=config.zero_tail_s,
            **_metadata_base(config),
        )
        _apply_generated_lengths(metadata, (x, y), sample_rate_hz=config.sample_rate_hz)
        return GeneratedWaveforms(ch1=x, ch2=y, metadata=metadata)

    if mode == "burst":
        x_python_freq_hz = python_frequency_hz(config.x_freq_hz, config.rfdc_interpolation)
        y_python_freq_hz = python_frequency_hz(config.y_freq_hz, config.rfdc_interpolation)
        x = waveform_tools.make_gaussian_burst(
            x_python_freq_hz,
            config.x_phase_rad,
            config.amplitude,
            config.sample_rate_hz,
            config.duration_s,
        )
        y = waveform_tools.make_gaussian_burst(
            y_python_freq_hz,
            config.y_phase_rad,
            config.amplitude,
            config.sample_rate_hz,
            config.duration_s,
        )
        if not np.any(x) or not np.any(y):
            raise ValueError("burst mode produced all-zero samples; check duration, delay, amplitude, and sample rate")
        metadata = waveform_tools.build_metadata(
            mode="burst",
            sample_rate_hz=config.sample_rate_hz,
            axis_freq_hz=config.axis_freq_hz,
            encoding="signed",
            loop=config.loop,
            layout=config.ddr_layout,
            ch1_freq_hz=config.x_freq_hz,
            ch2_freq_hz=config.y_freq_hz,
            ch1_phase_rad=config.x_phase_rad,
            ch2_phase_rad=config.y_phase_rad,
            ch1_delay_s=config.x_delay_s,
            ch2_delay_s=config.y_delay_s,
            ch1_delay_cycles=waveform_tools.delay_seconds_to_axis_cycles_by_freq(config.x_delay_s, config.axis_freq_hz),
            ch2_delay_cycles=waveform_tools.delay_seconds_to_axis_cycles_by_freq(config.y_delay_s, config.axis_freq_hz),
            duration_s=config.duration_s,
            amplitude=config.amplitude,
            ch1_scope_freq_hz=config.x_freq_hz,
            ch2_scope_freq_hz=config.y_freq_hz,
            ch1_python_freq_hz=x_python_freq_hz,
            ch2_python_freq_hz=y_python_freq_hz,
            **_metadata_base(config),
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
            layout=config.ddr_layout,
            ch1_start=config.x_start,
            ch2_start=config.y_start,
            **_metadata_base(config),
        )
        return GeneratedWaveforms(ch1=x, ch2=y, metadata=metadata)

    raise ValueError(f"Unsupported waveform mode: {config.mode}")


def _ezq_xy_baseband_hz(ezq: EzqPulseConfig | EzqChannelConfig) -> float:
    return float(ezq.f10_hz) - float(ezq.fc_hz) + float(ezq.pi_df_hz)


def _ezq_readout_baseband_hz(ezq: EzqPulseConfig) -> float:
    return float(ezq.readout_freq_hz) - float(ezq.readout_fc_hz)


def _ezq_amplitude_codes(normalized: float) -> int:
    return int(round(np.clip(float(normalized), -1.0, 1.0) * 32767.0))


def _hls_time_axis_ns(sample_count: int, sample_rate_hz: float, duration_s: float) -> tuple[np.ndarray, np.ndarray]:
    complex_sample_count = int(sample_count) // 2
    t_s = np.arange(complex_sample_count, dtype=np.float64) / float(sample_rate_hz)
    t_ns = (t_s * 1e9) - (float(duration_s) * 0.5e9)
    return t_s, t_ns


def _hls_time_axis_from_zero_ns(sample_count: int, sample_rate_hz: float) -> tuple[np.ndarray, np.ndarray]:
    complex_sample_count = int(sample_count) // 2
    t_s = np.arange(complex_sample_count, dtype=np.float64) / float(sample_rate_hz)
    return t_s, t_s * 1e9


def _hls_gaussian_ns(t_ns: np.ndarray, center_ns: float, fwhm_ns: float, amp: float, phase_rad: float = 0.0) -> np.ndarray:
    sigma_ns = max(float(fwhm_ns) / 2.3548200, 1e-12)
    env = float(amp) * np.exp(-0.5 * ((t_ns - float(center_ns)) / sigma_ns) ** 2)
    return env * np.exp(1j * float(phase_rad))


def _erf_array(values: np.ndarray) -> np.ndarray:
    return np.fromiter((math.erf(float(value)) for value in values), dtype=np.float64, count=int(values.size))


def _hls_flattop_ns(t_ns: np.ndarray, t0_ns: float, dt_ns: float, edge_ns: float, amp: float) -> np.ndarray:
    t_min = min(float(t0_ns), float(t0_ns) + float(dt_ns))
    t_max = max(float(t0_ns), float(t0_ns) + float(dt_ns))
    a = 1.66511 / max(float(edge_ns), 1e-12)
    return float(amp) * (_erf_array(a * (t_max - t_ns)) - _erf_array(a * (t_min - t_ns))) / 2.0


def _hls_mix(t_s: np.ndarray, wave: np.ndarray, baseband_hz: float, phase_rad: float = 0.0) -> np.ndarray:
    angle = -(2.0 * np.pi * float(baseband_hz) * t_s) - float(phase_rad)
    return wave * np.exp(1j * angle)


def _pack_complex_iq(wave: np.ndarray, sample_count: int) -> np.ndarray:
    i_wave = np.round(np.clip(np.real(wave), -32767.0, 32767.0)).astype(np.int16)
    q_wave = np.round(np.clip(np.imag(wave), -32767.0, 32767.0)).astype(np.int16)
    return waveform_tools.pack_iq_tile_buffer(i_wave, q_wave, sample_count=int(sample_count))


def _ezq_global_channel_config(ezq: EzqPulseConfig, channel: int) -> EzqChannelConfig:
    role = _fixed_channel_role(channel)
    readout_target_hz = host.DEFAULT_READOUT_TARGET_RF_HZ.get(int(channel), float(ezq.readout_freq_hz))
    return EzqChannelConfig(
        enabled=_ezq_channel_enabled(ezq, channel),
        waveform=role,
        xy_gate="x_pi",
        target_rf_hz=readout_target_hz if role == "readout" else 0.0,
        detune_hz=float(ezq.pi_df_hz) if role == "xy" else 0.0,
        start_time_s=0.0,
        f10_hz=float(ezq.f10_hz),
        f21_hz=float(ezq.f21_hz),
        fc_hz=float(ezq.fc_hz),
        nonlinearity_hz=float(ezq.nonlinearity_hz),
        pi_amp=float(ezq.pi_amp),
        pi_len_s=float(ezq.pi_len_s),
        pi_fwhm_s=float(ezq.pi_fwhm_s),
        pi_alpha=float(ezq.pi_alpha),
        pi_amp_half=float(ezq.pi_amp_half),
        pi_len_half_s=float(ezq.pi_len_half_s),
        pi_fwhm_half_s=float(ezq.pi_fwhm_half_s),
        pi_alpha_half=float(ezq.pi_alpha_half),
        pi_amp21=float(ezq.pi_amp21),
        pi_amp21_half=float(ezq.pi_amp21_half),
        pi_df_hz=float(ezq.pi_df_hz),
        xy_phase_rad=float(ezq.xy_phase_rad),
        spec_amp=float(ezq.spec_amp),
        spec_len_s=float(ezq.spec_len_s),
        z_amp=float(ezq.pi_amp_z),
        z_len_s=float(ezq.pi_len_z_s),
        z_shape=str(ezq.z_shape),
        z_start_s=float(ezq.z_start_s),
        z_gate_time_s=float(ezq.z_gate_time_s),
        z_edge_s=float(ezq.z_edge_s),
        z_ripple0=float(ezq.z_ripple0),
        z_ripple1=float(ezq.z_ripple1),
        z_ripple2=float(ezq.z_ripple2),
        z_ripple3=float(ezq.z_ripple3),
        readout_freq_hz=readout_target_hz if role == "readout" else float(ezq.readout_freq_hz),
        readout_fc_hz=readout_target_hz if role == "readout" else float(ezq.readout_fc_hz),
        readout_amp=0.5,
        readout_len_s=float(ezq.readout_len_s),
        readout_start_s=float(ezq.readout_start_s),
        readout_phase_rad=0.0,
        readout_edge_s=float(ezq.readout_edge_s),
        readout_flattop_s=float(ezq.readout_flattop_s),
        readout_zpa=float(ezq.readout_zpa),
        timing_lag_xy_s=float(ezq.timing_lag_xy_s),
        period_s=float(ezq.period_s),
    )


def _ezq_effective_channel_config(ezq: EzqPulseConfig, channel: int) -> EzqChannelConfig:
    channel_config = getattr(ezq, f"ch{int(channel)}")
    role = _fixed_channel_role(channel)
    if channel_config is not None and str(channel_config.waveform).lower() == role:
        return channel_config
    if channel_config is not None and role == "readout":
        readout_target_hz = host.DEFAULT_READOUT_TARGET_RF_HZ.get(int(channel), float(ezq.readout_freq_hz))
        return replace(
            channel_config,
            waveform=role,
            target_rf_hz=readout_target_hz,
            readout_freq_hz=readout_target_hz,
            readout_fc_hz=readout_target_hz,
        )
    if channel_config is not None:
        return replace(channel_config, waveform=role)
    return _ezq_global_channel_config(ezq, channel)


def _fixed_channel_role(channel: int) -> str:
    return str(host.CHANNEL_ROLES.get(int(channel), "xy"))


def _ezq_channel_enabled(ezq: EzqPulseConfig, channel: int) -> bool:
    return bool(int(ezq.channel_mask) & (1 << (int(channel) - 1)))


def _ezq_channel_waveform(config: EzqChannelConfig) -> str:
    waveform = str(config.waveform).lower()
    if waveform not in {"xy", "z", "readout"}:
        raise ValueError("ezq channel waveform must be one of: xy, z, readout")
    return waveform


def _ezq_effective_role(channel: int, _config: EzqChannelConfig) -> str:
    return _fixed_channel_role(channel)


def _ezq_xy_gate(config: EzqChannelConfig) -> str:
    gate = str(config.xy_gate).lower()
    if gate not in {"x_pi", "y_pi", "x_half", "y_half", "x12_pi", "x12_half", "spec"}:
        raise ValueError("ezq XY gate must be one of: x_pi, y_pi, x_half, y_half, x12_pi, x12_half, spec")
    return gate


def _ezq_xy_gate_parameters(config: EzqChannelConfig) -> dict[str, float | str]:
    gate = _ezq_xy_gate(config)
    phase = float(config.xy_phase_rad)
    if gate.startswith("y_"):
        phase += np.pi / 2.0
    if gate == "x12_pi":
        return {
            "gate": gate,
            "baseband_hz": float(config.f21_hz) - float(config.fc_hz) + float(config.pi_df_hz),
            "amp": float(config.pi_amp21),
            "duration_s": float(config.pi_len_s),
            "fwhm_s": float(config.pi_fwhm_s),
            "alpha": float(config.pi_alpha),
            "phase_rad": phase,
        }
    if gate == "x12_half":
        return {
            "gate": gate,
            "baseband_hz": float(config.f21_hz) - float(config.fc_hz) + float(config.pi_df_hz),
            "amp": float(config.pi_amp21_half),
            "duration_s": float(config.pi_len_half_s),
            "fwhm_s": float(config.pi_fwhm_half_s),
            "alpha": float(config.pi_alpha_half),
            "phase_rad": phase,
        }
    if gate == "spec":
        return {
            "gate": gate,
            "baseband_hz": float(config.f10_hz) - float(config.fc_hz) + float(config.pi_df_hz),
            "amp": float(config.spec_amp),
            "duration_s": float(config.spec_len_s),
            "fwhm_s": max(float(config.spec_len_s) * 0.5, 1e-9),
            "alpha": 0.0,
            "phase_rad": phase,
        }
    if gate in {"x_half", "y_half"}:
        return {
            "gate": gate,
            "baseband_hz": float(config.f10_hz) - float(config.fc_hz) + float(config.pi_df_hz),
            "amp": float(config.pi_amp_half),
            "duration_s": float(config.pi_len_half_s),
            "fwhm_s": float(config.pi_fwhm_half_s),
            "alpha": float(config.pi_alpha_half),
            "phase_rad": phase,
        }
    return {
        "gate": gate,
        "baseband_hz": float(config.f10_hz) - float(config.fc_hz) + float(config.pi_df_hz),
        "amp": float(config.pi_amp),
        "duration_s": float(config.pi_len_s),
        "fwhm_s": float(config.pi_fwhm_s),
        "alpha": float(config.pi_alpha),
        "phase_rad": phase,
    }


def _ezq_channel_duration_s(config: EzqChannelConfig, role: str | None = None) -> float:
    waveform = str(role or _ezq_channel_waveform(config)).lower()
    if waveform == "z":
        return max(float(config.z_len_s), float(config.z_start_s) + float(config.z_gate_time_s))
    if waveform == "readout":
        return float(config.readout_len_s)
    return float(_ezq_xy_gate_parameters(config)["duration_s"])


def _ezq_channel_target_rf_hz(channel: int, config: EzqChannelConfig, role: str | None = None) -> float:
    waveform = str(role or _ezq_effective_role(channel, config)).lower()
    if waveform == "z":
        return 0.0
    if float(config.target_rf_hz) > 0.0:
        return float(config.target_rf_hz)
    if waveform == "readout":
        return float(config.readout_freq_hz)
    gate = _ezq_xy_gate(config)
    if gate in {"x12_pi", "x12_half"}:
        return float(config.f21_hz)
    return float(config.f10_hz)


def _ezq_channel_baseband_hz(config: EzqChannelConfig, role: str | None = None) -> float:
    waveform = str(role or _ezq_channel_waveform(config)).lower()
    if waveform == "z":
        return 0.0
    detune = float(config.detune_hz)
    if abs(detune) > 0.0:
        return detune
    if waveform == "xy":
        return float(config.pi_df_hz)
    return 0.0


def _record_int16_sample_count(record_duration_s: float, sample_rate_hz: float) -> int:
    if float(record_duration_s) <= 0.0:
        raise ValueError("record_duration_s must be positive")
    complex_samples = max(1, int(round(float(record_duration_s) * float(sample_rate_hz))))
    if complex_samples % 8 != 0:
        complex_samples += 8 - (complex_samples % 8)
    return complex_samples * 2


def _place_iq_wave_in_record(
    active_wave: np.ndarray,
    start_time_s: float,
    record_sample_count: int,
    sample_rate_hz: float,
    channel: int,
) -> np.ndarray:
    active = np.asarray(active_wave, dtype=np.int16).reshape(-1)
    if active.size % 2 != 0:
        raise ValueError(f"ezq CH{channel} active wave must contain whole I/Q complex samples")
    start_complex = max(0, int(round(float(start_time_s) * float(sample_rate_hz))))
    start_int16 = start_complex * 2
    end_int16 = start_int16 + active.size
    if end_int16 > int(record_sample_count):
        record_ns = (int(record_sample_count) // 2) / float(sample_rate_hz) * 1e9
        end_ns = end_int16 / 2.0 / float(sample_rate_hz) * 1e9
        raise ValueError(
            f"ezq CH{channel} pulse exceeds record_duration_s: "
            f"pulse end {end_ns:g} ns > record {record_ns:g} ns"
        )
    record = np.zeros(int(record_sample_count), dtype=np.int16)
    record[start_int16:end_int16] = active
    return record


def _make_ezq_z_waveform(config: EzqChannelConfig, sample_rate_hz: float, sample_count: int) -> np.ndarray:
    _, t_ns = _hls_time_axis_from_zero_ns(sample_count, sample_rate_hz)
    amp_codes = float(_ezq_amplitude_codes(config.z_amp))
    z_shape = str(config.z_shape).lower()
    ripple_values = [config.z_ripple0, config.z_ripple1, config.z_ripple2, config.z_ripple3] if z_shape == "diabatic_cz" else [0.0, 0.0, 0.0, 0.0]
    ripples = np.array(ripple_values, dtype=np.float64) * amp_codes
    base_amp = amp_codes - ripples[1] - ripples[3]
    t0_ns = float(config.z_start_s) * 1e9
    gate_ns = float(config.z_gate_time_s) * 1e9
    edge_ns = float(config.z_edge_s) * 1e9
    t_min = min(t0_ns, t0_ns + gate_ns)
    t_max = max(t0_ns, t0_ns + gate_ns)
    t_mid = (t_min + t_max) / 2.0

    window_size = 240
    t_step_ns = 0.05
    window_t_ns = (np.arange(window_size, dtype=np.float64) * t_step_ns) - (3.0 * edge_ns)
    window = np.real(_hls_gaussian_ns(window_t_ns, 0.0, edge_ns, 0.94 / max(edge_ns, 1e-12), 0.0))
    window_sum = float(np.sum(window))
    if abs(window_sum) < 1e-12:
        raise ValueError("ezq Z edge width is too small for HLS diabatic-CZ window")

    z_wave = np.zeros_like(t_ns, dtype=np.float64)
    for index, t_value_ns in enumerate(t_ns):
        current_t = t_value_ns - (3.0 * edge_ns) + (np.arange(window_size, dtype=np.float64) * t_step_ns)
        ripple_wave = np.zeros(window_size, dtype=np.float64)
        if gate_ns > 0.0:
            for ripple_index, ripple_amp in enumerate(ripples):
                idx_r = float(2 ** (ripple_index // 2))
                angle = idx_r * np.pi * (current_t - t_mid) / gate_ns
                if ripple_index % 2 == 0:
                    ripple_wave += ripple_amp * np.sin(angle)
                else:
                    ripple_wave += ripple_amp * np.cos(angle)
        rect = np.logical_and(current_t >= t_min, current_t < t_max).astype(np.float64)
        z_wave[index] = float(np.sum((window / window_sum) * (base_amp + ripple_wave) * rect))
    return waveform_tools.pack_iq_tile_buffer(
        np.round(np.clip(z_wave, -32767.0, 32767.0)).astype(np.int16),
        np.zeros_like(z_wave, dtype=np.int16),
        sample_count=int(sample_count),
    )


def _make_ezq_readout_waveform(
    config: EzqChannelConfig,
    sample_rate_hz: float,
    sample_count: int,
    baseband_hz: float,
) -> np.ndarray:
    t_s, t_ns = _hls_time_axis_from_zero_ns(sample_count, sample_rate_hz)
    amp_codes = float(_ezq_amplitude_codes(config.readout_amp))
    edge_ns = float(config.readout_edge_s) * 1e9
    flattop_ns = float(config.readout_flattop_s) * 1e9
    start_ns = float(config.readout_start_s) * 1e9
    gaussian = _hls_gaussian_ns(t_ns, start_ns + 30.0, edge_ns, amp_codes, float(config.readout_phase_rad))
    flattop = _hls_flattop_ns(t_ns, start_ns, flattop_ns, edge_ns, amp_codes).astype(np.complex128)
    wave = _hls_mix(t_s, gaussian + flattop, baseband_hz, 0.0)
    return _pack_complex_iq(wave, int(sample_count))


def _generate_ezq_quantum_waveforms(config: WaveformConfig) -> GeneratedWaveforms:
    ezq = config.ezq
    if int(ezq.repeat) < 1:
        raise ValueError("ezq repeat must be at least 1")

    record_sample_count = _record_int16_sample_count(ezq.record_duration_s, config.sample_rate_hz)
    record_complex_samples = record_sample_count // 2
    waves: dict[int, np.ndarray] = {}
    per_channel_nco: dict[str, float] = {}
    per_channel_zone: dict[str, int] = {}
    channel_roles: dict[str, str] = {}

    for channel in range(1, 9):
        channel_config = _ezq_effective_channel_config(ezq, channel)
        waveform = _ezq_effective_role(channel, channel_config)
        channel_roles[f"ch{channel}"] = waveform
        duration_s = _ezq_channel_duration_s(channel_config, waveform)
        if duration_s <= 0.0:
            raise ValueError(f"ezq CH{channel} {waveform} duration must be positive")
        xy_params = _ezq_xy_gate_parameters(channel_config) if waveform == "xy" else None
        if waveform == "xy" and float(xy_params["fwhm_s"]) <= 0.0:
            raise ValueError(f"ezq CH{channel} XY fwhm must be positive")
        if waveform == "z":
            if float(channel_config.z_gate_time_s) <= 0.0:
                raise ValueError(f"ezq CH{channel} z_gate_time_s must be positive")
            if float(channel_config.z_edge_s) <= 0.0:
                raise ValueError(f"ezq CH{channel} z_edge_s must be positive")
        if waveform == "readout":
            if float(channel_config.readout_edge_s) <= 0.0:
                raise ValueError(f"ezq CH{channel} readout_edge_s must be positive")
            if float(channel_config.readout_flattop_s) <= 0.0:
                raise ValueError(f"ezq CH{channel} readout_flattop_s must be positive")
        active_samples = waveform_tools.iq_duration_to_sample_count(duration_s, config.sample_rate_hz)
        baseband_hz = _ezq_channel_baseband_hz(channel_config, waveform)
        if abs(baseband_hz) > host.DEFAULT_BASEBAND_OFFSET_LIMIT_HZ:
            raise ValueError(
                f"ezq CH{channel} baseband offset {baseband_hz / 1e6:g} MHz exceeds "
                f"the recommended +/-{host.DEFAULT_BASEBAND_OFFSET_LIMIT_HZ / 1e6:g} MHz limit"
            )
        target_rf_hz = _ezq_channel_target_rf_hz(channel, channel_config, waveform)
        if waveform == "z":
            nco_plan = {"nco_hz": 0.0, "nyquist_zone": 1}
        else:
            nco_plan = host.rfdc_nco_plan_for_target(target_rf_hz)
        per_channel_nco[f"ch{channel}"] = float(nco_plan["nco_hz"])
        per_channel_zone[f"ch{channel}"] = int(nco_plan["nyquist_zone"])
        if channel_config.enabled:
            if waveform == "xy":
                if xy_params is None:
                    raise ValueError(f"ezq CH{channel} XY gate parameters are unavailable")
                _validate_iq_frequency(baseband_hz, config.sample_rate_hz, f"ezq CH{channel} XY")
                use_drag = abs(float(xy_params["alpha"])) > 1e-12 and abs(float(channel_config.nonlinearity_hz)) >= 1.0
                wave = waveform_tools.make_iq_gaussian_sine_tile_waveform(
                    baseband_hz,
                    float(xy_params["phase_rad"]),
                    _ezq_amplitude_codes(float(xy_params["amp"])),
                    config.sample_rate_hz,
                    float(xy_params["duration_s"]),
                    sample_count=active_samples,
                    fwhm_s=float(xy_params["fwhm_s"]),
                    q_sign=-1,
                    hls_xy_drag=use_drag,
                    drag_alpha=float(xy_params["alpha"]),
                    drag_delta_hz=float(channel_config.nonlinearity_hz) if use_drag else -200e6,
                )
            elif waveform == "z":
                wave = _make_ezq_z_waveform(channel_config, config.sample_rate_hz, active_samples)
            else:
                _validate_iq_frequency(baseband_hz, config.sample_rate_hz, f"ezq CH{channel} readout")
                wave = _make_ezq_readout_waveform(channel_config, config.sample_rate_hz, active_samples, baseband_hz)
        else:
            wave = np.zeros(active_samples, dtype=np.int16)
        waves[channel] = _place_iq_wave_in_record(
            wave,
            channel_config.start_time_s,
            record_sample_count,
            config.sample_rate_hz,
            channel,
        )

    metadata = waveform_tools.build_metadata(
        mode="ezq-quantum",
        sample_rate_hz=config.sample_rate_hz,
        axis_freq_hz=config.axis_freq_hz,
        encoding="signed-iq-interleaved",
        loop=False,
        layout=config.ddr_layout,
        ch1_label=CHANNEL_LABELS["ch1"],
        ch2_label=CHANNEL_LABELS["ch2"],
        ch3_label=CHANNEL_LABELS["ch3"],
        ch4_label=CHANNEL_LABELS["ch4"],
        ch5_label=CHANNEL_LABELS["ch5"],
        ch6_label=CHANNEL_LABELS["ch6"],
        ch7_label=CHANNEL_LABELS["ch7"],
        ch8_label=CHANNEL_LABELS["ch8"],
        ezq=_ezq_metadata(config),
        dac_fs=float(host.DAC_TILE_FS),
        interpolation=int(host.DAC_INTERP),
        record_samples=record_complex_samples,
        record_bytes=record_sample_count * 2,
        physical_ddr_bytes=record_sample_count * 2 * 8,
        channel_roles=channel_roles,
        per_channel_nco=per_channel_nco,
        per_channel_zone=per_channel_zone,
        **_metadata_base(config),
    )
    for channel in range(1, 9):
        channel_config = _ezq_effective_channel_config(ezq, channel)
        role = _ezq_effective_role(channel, channel_config)
        baseband_hz = _ezq_channel_baseband_hz(channel_config, role)
        metadata[f"ch{channel}"] = _ezq_channel_metadata(
            config,
            channel,
            channel_config,
            role,
            baseband_hz,
            target_rf_hz=_ezq_channel_target_rf_hz(channel, channel_config, role),
            nco_hz=per_channel_nco[f"ch{channel}"],
            nyquist_zone=per_channel_zone[f"ch{channel}"],
            active_duration_s=_ezq_channel_duration_s(channel_config, role),
        )
        metadata[f"ch{channel}_delay_cycles"] = metadata[f"ch{channel}"]["delay_cycles"]
    _apply_generated_lengths(
        metadata,
        (waves[1], waves[2], waves[3], waves[4], waves[5], waves[6], waves[7], waves[8]),
        sample_rate_hz=config.sample_rate_hz,
    )
    return GeneratedWaveforms(
        ch1=waves[1],
        ch2=waves[2],
        ch3=waves[3],
        ch4=waves[4],
        ch5=waves[5],
        ch6=waves[6],
        ch7=waves[7],
        ch8=waves[8],
        metadata=metadata,
    )


def _ezq_metadata(config: WaveformConfig) -> dict[str, object]:
    ezq = config.ezq
    return {
        **_ezq_config_to_dict(ezq),
        "xy_baseband_hz": float(ezq.pi_df_hz),
        "readout_baseband_hz": 0.0,
        "amplitude_codes": _ezq_amplitude_codes(ezq.pi_amp),
        "format": "ezq-like gate-profile input compiled to RFSoC per-channel IQ buffers",
        "frequency_rule": "target_rf_hz/f10/readout_freq selects RFDC NCO; detune_hz/pi_df_hz is the small software baseband offset",
        "timing_rule": "start_time_s places each pulse on a shared zero-padded record; hardware channel delay is 0 in interleaved_512b mode",
        "generation_reference": "HLS gen_wave.cpp env_gaussian/rotPulseHD_xy/env_diabaticCZ/readout_construction",
    }


def _ezq_channel_metadata(
    config: WaveformConfig,
    channel: int,
    channel_config: EzqChannelConfig,
    role: str,
    baseband_hz: float,
    target_rf_hz: float,
    nco_hz: float,
    nyquist_zone: int,
    active_duration_s: float,
) -> dict[str, object]:
    delay_s = 0.0
    delay_cycles = 0
    enabled = bool(channel_config.enabled)
    waveform = str(role).lower()
    xy_params = _ezq_xy_gate_parameters(channel_config) if waveform == "xy" else None
    if waveform == "z":
        amplitude_codes = _ezq_amplitude_codes(channel_config.z_amp)
        duration_s = active_duration_s
        phase_rad = 0.0
    elif waveform == "readout":
        amplitude_codes = _ezq_amplitude_codes(channel_config.readout_amp)
        duration_s = active_duration_s
        phase_rad = float(channel_config.readout_phase_rad)
    else:
        if xy_params is None:
            raise ValueError(f"ezq CH{channel} XY gate parameters are unavailable")
        amplitude_codes = _ezq_amplitude_codes(float(xy_params["amp"]))
        duration_s = active_duration_s
        phase_rad = float(xy_params["phase_rad"])
    return {
        "label": CHANNEL_LABELS[f"ch{channel}"],
        "upload_arg": CHANNEL_UPLOAD_ARGS[f"ch{channel}"],
        "type": f"ezq-{waveform}" if enabled else "off",
        "waveform": waveform,
        "xy_gate": _ezq_xy_gate(channel_config) if waveform == "xy" else "",
        "role": waveform,
        "enabled": enabled,
        "encoding": "signed-iq-interleaved",
        "semantics": f"ez-Q-like {waveform.upper()} pulse" if enabled else "disabled channel",
        "start_time_s": float(channel_config.start_time_s),
        "target_rf_hz": float(target_rf_hz),
        "nco_hz": float(nco_hz),
        "nyquist_zone": int(nyquist_zone),
        "detune_hz": float(baseband_hz),
        "f10_hz": float(channel_config.f10_hz),
        "f21_hz": float(channel_config.f21_hz),
        "fc_hz": float(channel_config.fc_hz),
        "nonlinearity_hz": float(channel_config.nonlinearity_hz),
        "readout_freq_hz": float(channel_config.readout_freq_hz),
        "readout_fc_hz": float(channel_config.readout_fc_hz),
        "freq_hz": float(baseband_hz),
        "scope_freq_hz": float(baseband_hz),
        "python_freq_hz": float(baseband_hz),
        "phase_rad": phase_rad,
        "pi_df_hz": float(channel_config.pi_df_hz),
        "pi_amp": float(channel_config.pi_amp),
        "pi_amp_half": float(channel_config.pi_amp_half),
        "pi_amp21": float(channel_config.pi_amp21),
        "pi_amp21_half": float(channel_config.pi_amp21_half),
        "spec_amp": float(channel_config.spec_amp),
        "z_amp": float(channel_config.z_amp),
        "readout_amp": float(channel_config.readout_amp),
        "amplitude": int(amplitude_codes),
        "duration_s": duration_s,
        "pi_len_s": float(channel_config.pi_len_s),
        "pi_fwhm_s": float(channel_config.pi_fwhm_s),
        "pi_alpha": float(channel_config.pi_alpha),
        "pi_len_half_s": float(channel_config.pi_len_half_s),
        "pi_fwhm_half_s": float(channel_config.pi_fwhm_half_s),
        "pi_alpha_half": float(channel_config.pi_alpha_half),
        "spec_len_s": float(channel_config.spec_len_s),
        "z_len_s": float(channel_config.z_len_s),
        "z_shape": str(channel_config.z_shape),
        "z_start_s": float(channel_config.z_start_s),
        "z_gate_time_s": float(channel_config.z_gate_time_s),
        "z_edge_s": float(channel_config.z_edge_s),
        "z_ripples": [
            float(channel_config.z_ripple0),
            float(channel_config.z_ripple1),
            float(channel_config.z_ripple2),
            float(channel_config.z_ripple3),
        ],
        "readout_len_s": float(channel_config.readout_len_s),
        "readout_start_s": float(channel_config.readout_start_s),
        "readout_edge_s": float(channel_config.readout_edge_s),
        "readout_flattop_s": float(channel_config.readout_flattop_s),
        "readout_zpa": float(channel_config.readout_zpa),
        "drag_enabled": bool(
            xy_params is not None
            and abs(float(xy_params["alpha"])) > 1e-12
            and abs(float(channel_config.nonlinearity_hz)) >= 1.0
        ),
        "backend": {
            "xy": "hls-drag-gaussian",
            "z": "hls-diabatic-cz",
            "readout": "hls-gaussian-plus-flattop",
        }[waveform],
        "zero_tail_s": 0.0,
        "delay_s": delay_s,
        "delay_cycles": delay_cycles,
        "repeat": int(config.ezq.repeat),
        "period_s": float(channel_config.period_s),
    }


def _generate_independent_waveforms(config: WaveformConfig) -> GeneratedWaveforms:
    ch1_config = config.ch1 or ChannelWaveformConfig(waveform_type="off")
    ch2_config = config.ch2 or ChannelWaveformConfig(waveform_type="off")
    ch3_config = config.ch3 or ChannelWaveformConfig(waveform_type="off")
    ch4_config = config.ch4 or ChannelWaveformConfig(waveform_type="off")
    ch5_config = config.ch5 or ChannelWaveformConfig(waveform_type="off")
    ch6_config = config.ch6 or ChannelWaveformConfig(waveform_type="off")
    ch7_config = config.ch7 or ChannelWaveformConfig(waveform_type="off")
    ch8_config = config.ch8 or ChannelWaveformConfig(waveform_type="off")
    x = _make_channel_waveform(ch1_config, config.sample_rate_hz, config.rfdc_interpolation, "ch1")
    y = _make_channel_waveform(ch2_config, config.sample_rate_hz, config.rfdc_interpolation, "ch2")
    ch3 = _make_channel_waveform(ch3_config, config.sample_rate_hz, config.rfdc_interpolation, "ch3")
    ch4 = _make_channel_waveform(ch4_config, config.sample_rate_hz, config.rfdc_interpolation, "ch4")
    ch5 = _make_channel_waveform(ch5_config, config.sample_rate_hz, config.rfdc_interpolation, "ch5")
    ch6 = _make_channel_waveform(ch6_config, config.sample_rate_hz, config.rfdc_interpolation, "ch6")
    ch7 = _make_channel_waveform(ch7_config, config.sample_rate_hz, config.rfdc_interpolation, "ch7")
    ch8 = _make_channel_waveform(ch8_config, config.sample_rate_hz, config.rfdc_interpolation, "ch8")
    metadata = waveform_tools.build_metadata(
        mode="per-channel",
        sample_rate_hz=config.sample_rate_hz,
        encoding="mixed-per-channel",
        loop=config.loop,
        layout=config.ddr_layout,
        ch1_label=CHANNEL_LABELS["ch1"],
        ch2_label=CHANNEL_LABELS["ch2"],
        ch3_label=CHANNEL_LABELS["ch3"],
        ch4_label=CHANNEL_LABELS["ch4"],
        ch5_label=CHANNEL_LABELS["ch5"],
        ch6_label=CHANNEL_LABELS["ch6"],
        ch7_label=CHANNEL_LABELS["ch7"],
        ch8_label=CHANNEL_LABELS["ch8"],
        ch1=_channel_metadata(ch1_config, "ch1", config.axis_freq_hz, config.rfdc_interpolation, config.sample_rate_hz),
        ch2=_channel_metadata(ch2_config, "ch2", config.axis_freq_hz, config.rfdc_interpolation, config.sample_rate_hz),
        ch3=_channel_metadata(ch3_config, "ch3", config.axis_freq_hz, config.rfdc_interpolation, config.sample_rate_hz),
        ch4=_channel_metadata(ch4_config, "ch4", config.axis_freq_hz, config.rfdc_interpolation, config.sample_rate_hz),
        ch5=_channel_metadata(ch5_config, "ch5", config.axis_freq_hz, config.rfdc_interpolation, config.sample_rate_hz),
        ch6=_channel_metadata(ch6_config, "ch6", config.axis_freq_hz, config.rfdc_interpolation, config.sample_rate_hz),
        ch7=_channel_metadata(ch7_config, "ch7", config.axis_freq_hz, config.rfdc_interpolation, config.sample_rate_hz),
        ch8=_channel_metadata(ch8_config, "ch8", config.axis_freq_hz, config.rfdc_interpolation, config.sample_rate_hz),
        **_metadata_base(config),
    )
    _apply_generated_lengths(
        metadata,
        (x, y, ch3, ch4, ch5, ch6, ch7, ch8),
        sample_rate_hz=config.sample_rate_hz,
    )
    return GeneratedWaveforms(ch1=x, ch2=y, ch3=ch3, ch4=ch4, ch5=ch5, ch6=ch6, ch7=ch7, ch8=ch8, metadata=metadata)


def _apply_generated_lengths(metadata: dict[str, Any], waves: tuple[np.ndarray, ...], sample_rate_hz: float) -> None:
    max_samples = 0
    max_bytes = 0
    for channel, wave in enumerate(waves, start=1):
        samples = int(np.asarray(wave).size)
        length_bytes = waveform_tools.waveform_length_bytes(wave)
        max_samples = max(max_samples, samples)
        max_bytes = max(max_bytes, length_bytes)
        metadata[f"ch{channel}_logical_bytes"] = length_bytes
        metadata[f"ch{channel}_samples_per_channel"] = samples
        metadata[f"ch{channel}_complex_samples"] = samples // 2
        metadata[f"ch{channel}_record_duration_s"] = (samples // 2) / float(sample_rate_hz)
        channel_meta = metadata.get(f"ch{channel}")
        if isinstance(channel_meta, dict):
            channel_meta["samples_per_channel"] = samples
            channel_meta["bytes"] = length_bytes
            channel_meta["complex_samples"] = samples // 2
            channel_meta["record_duration_s"] = (samples // 2) / float(sample_rate_hz)
    metadata["samples_per_channel"] = max_samples
    metadata["bytes_per_channel"] = max_bytes
    metadata["record_duration_s"] = (max_samples // 2) / float(sample_rate_hz)


def _make_channel_waveform(config: ChannelWaveformConfig, sample_rate_hz: float, rfdc_interpolation: int, channel_name: str) -> np.ndarray:
    waveform_type = config.waveform_type.lower()
    sample_count = waveform_tools.iq_duration_to_sample_count(config.duration_s, sample_rate_hz)
    if waveform_type == "off":
        return np.zeros(sample_count, dtype=np.int16)
    if waveform_type == "dc-iq-cw":
        wave = host.build_dc_iq_tone(sample_count * 2, amp=float(config.amplitude) / 32767.0)
        return waveform_tools.append_iq_zero_tail(wave, config.zero_tail_s, sample_rate_hz)
    if waveform_type == "iq-sine":
        _validate_iq_frequency(config.freq_hz, sample_rate_hz, channel_name)
        wave = waveform_tools.make_iq_sine_tile_waveform(
            python_frequency_hz(config.freq_hz, rfdc_interpolation),
            config.phase_rad,
            config.amplitude,
            sample_rate_hz,
            sample_count=sample_count,
            q_sign=-1,
        )
        return waveform_tools.append_iq_zero_tail(wave, config.zero_tail_s, sample_rate_hz)
    if waveform_type == "iq-gaussian-sine":
        _validate_iq_frequency(config.freq_hz, sample_rate_hz, channel_name)
        wave = waveform_tools.make_iq_gaussian_sine_tile_waveform(
            python_frequency_hz(config.freq_hz, rfdc_interpolation),
            config.phase_rad,
            config.amplitude,
            sample_rate_hz,
            config.duration_s,
            sample_count=sample_count,
            q_sign=-1,
        )
        return waveform_tools.append_iq_zero_tail(wave, config.zero_tail_s, sample_rate_hz)
    if waveform_type == "pypulse":
        wave, _metadata = waveform_tools.make_pypulse_tile_waveform(
            config.pypulse_waveform,
            python_frequency_hz(config.freq_hz, rfdc_interpolation),
            config.phase_rad,
            config.amplitude,
            sample_rate_hz,
            config.duration_s,
        )
        return wave
    if waveform_type == "pulse":
        return _make_channel_pulse(config, sample_rate_hz, rfdc_interpolation, channel_name)
    if waveform_type == "quantum":
        return _make_quantum_gate_waveform(config, sample_rate_hz, rfdc_interpolation, channel_name)
    if waveform_type == "sine":
        wave = waveform_tools.make_iq_sine_tile_waveform(
            python_frequency_hz(config.freq_hz, rfdc_interpolation),
            config.phase_rad,
            config.amplitude,
            sample_rate_hz,
            sample_count=sample_count,
            q_sign=-1,
        )
        return waveform_tools.append_iq_zero_tail(wave, config.zero_tail_s, sample_rate_hz)
    if waveform_type == "burst":
        wave = waveform_tools.make_gaussian_burst(
            python_frequency_hz(config.freq_hz, rfdc_interpolation),
            config.phase_rad,
            config.amplitude,
            sample_rate_hz,
            config.duration_s,
        )
        if not np.any(wave):
            raise ValueError(f"{channel_name} burst produced all-zero samples; check duration, delay, amplitude, and sample rate")
        return wave
    if waveform_type == "golden":
        return waveform_tools.make_incrementing_pattern(start=config.start)
    raise ValueError(f"Unsupported {channel_name} waveform type: {config.waveform_type}")


def _make_channel_pulse(config: ChannelWaveformConfig, sample_rate_hz: float, rfdc_interpolation: int, channel_name: str) -> np.ndarray:
    pulse = _channel_gaussian_burst(config, sample_rate_hz, rfdc_interpolation)
    preset = config.pulse_preset.lower()
    if preset in ("x", "y"):
        return pulse
    if preset == "z":
        if channel_name == "ch1":
            return pulse
        return (-pulse).astype(np.int16)
    raise ValueError("pulse preset must be one of: x, y, z")


def _make_quantum_gate_waveform(config: ChannelWaveformConfig, sample_rate_hz: float, rfdc_interpolation: int, channel_name: str) -> np.ndarray:
    gate = config.quantum_gate.lower()
    if gate == "x":
        return _channel_gaussian_burst(config, sample_rate_hz, rfdc_interpolation)
    if gate == "y":
        return _channel_gaussian_burst(config, sample_rate_hz, rfdc_interpolation, phase_offset_rad=np.pi / 2.0)
    if gate == "z":
        pulse = _channel_gaussian_window_pulse(config, sample_rate_hz)
        if channel_name == "ch1":
            return pulse
        return (-pulse).astype(np.int16)
    raise ValueError("quantum gate must be one of: x, y, z")


def _channel_gaussian_burst(config: ChannelWaveformConfig, sample_rate_hz: float, rfdc_interpolation: int, phase_offset_rad: float = 0.0) -> np.ndarray:
    wave = waveform_tools.make_gaussian_burst(
        python_frequency_hz(config.freq_hz, rfdc_interpolation),
        config.phase_rad + phase_offset_rad,
        config.amplitude,
        sample_rate_hz,
        config.duration_s,
    )
    if not np.any(wave):
        raise ValueError("Gaussian burst produced all-zero samples; check duration, delay, amplitude, and sample rate")
    return wave


def _channel_gaussian_window_pulse(config: ChannelWaveformConfig, sample_rate_hz: float) -> np.ndarray:
    wave = np.zeros(host.NUM_SAMPLES, dtype=np.int16)
    start = 0
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


def _channel_metadata(config: ChannelWaveformConfig, channel: str, axis_freq_hz: float, rfdc_interpolation: int, sample_rate_hz: float) -> dict:
    python_freq_hz = python_frequency_hz(config.freq_hz, rfdc_interpolation)
    pypulse_info = _pypulse_metadata(config)
    waveform_type = config.waveform_type.lower()
    sample_count = waveform_tools.iq_duration_to_sample_count(config.duration_s, sample_rate_hz)
    length_bytes = sample_count * 2
    return {
        "label": CHANNEL_LABELS[channel],
        "upload_arg": CHANNEL_UPLOAD_ARGS[channel],
        "type": waveform_type,
        "pypulse_waveform": pypulse_info["pypulse_waveform"],
        "i_signal": pypulse_info["i_signal"],
        "q_signal": pypulse_info["q_signal"],
        "quantum_gate": config.quantum_gate.lower(),
        "rotation_angle_rad": config.rotation_angle_rad,
        "virtual_z_phase_rad": config.virtual_z_phase_rad,
        "semantics": _channel_semantics(config),
        "pulse_backend": _pulse_backend(config),
        "freq_hz": config.freq_hz,
        "scope_freq_hz": config.freq_hz,
        "python_freq_hz": python_freq_hz,
        "phase_rad": config.phase_rad,
        "amplitude": config.amplitude,
        "encoding": "signed-iq-interleaved" if waveform_type in ("iq-sine", "iq-gaussian-sine", "sine", "dc-iq-cw", "pypulse") else config.encoding,
        "delay_s": config.delay_s,
        "delay_cycles": waveform_tools.delay_seconds_to_axis_cycles_by_freq(config.delay_s, axis_freq_hz),
        "duration_s": config.duration_s,
        "zero_tail_s": config.zero_tail_s,
        "samples_per_channel": sample_count,
        "bytes": length_bytes,
        "complex_samples": sample_count // 2,
        "pulse_preset": config.pulse_preset,
        "pulse_sigma_s": config.pulse_sigma_s,
        "pulse_center_s": config.pulse_center_s,
        "start": config.start,
    }


def _channel_semantics(config: ChannelWaveformConfig) -> str:
    waveform_type = config.waveform_type.lower()
    if waveform_type == "dc-iq-cw":
        return "DC complex baseband with interleaved I/Q lanes"
    if waveform_type == "iq-sine":
        return "continuous complex sine with interleaved I/Q lanes"
    if waveform_type == "iq-gaussian-sine":
        return "finite HLS/DRAG-style Gaussian-envelope complex sine with interleaved I/Q lanes"
    if waveform_type == "sine":
        return "continuous complex sine with interleaved I/Q lanes"
    if waveform_type == "pypulse":
        return f"PyPulse {config.pypulse_waveform.upper()} I/Q tile waveform"
    if waveform_type != "quantum":
        return "hardware waveform"
    gate = config.quantum_gate.lower()
    if gate == "x":
        return "X rotation drive on this DAC channel"
    if gate == "y":
        return "Y rotation drive with +90 degree phase on this DAC channel"
    if gate == "z":
        return "Z detuning-style phase pulse on DAC pair"
    return "unknown quantum operation"


def _pypulse_metadata(config: ChannelWaveformConfig) -> dict[str, str]:
    if config.waveform_type.lower() != "pypulse":
        return {"pypulse_waveform": "", "i_signal": "", "q_signal": ""}
    waveform_key = config.pypulse_waveform.lower()
    if waveform_key == "xy":
        return {"pypulse_waveform": "xy", "i_signal": "xy_i", "q_signal": "xy_q"}
    if waveform_key == "readout":
        return {"pypulse_waveform": "readout", "i_signal": "readout_i", "q_signal": "readout_q"}
    if waveform_key == "z":
        return {"pypulse_waveform": "z", "i_signal": "z_i", "q_signal": "zero_q"}
    raise ValueError("pypulse waveform must be one of: xy, z, readout")


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
    if config.mode.lower() == "ezq-quantum" and not _has_independent_channel_configs(config):
        channel_configs = {
            f"ch{channel}": ChannelWaveformConfig(
                waveform_type="ezq-xy" if _ezq_effective_channel_config(config.ezq, channel).enabled else "off",
                freq_hz=_ezq_xy_baseband_hz(_ezq_effective_channel_config(config.ezq, channel)),
            )
            for channel in range(1, 9)
        }
    else:
        channel_configs = {
            "ch1": config.ch1 or ChannelWaveformConfig(waveform_type=config.mode),
            "ch2": config.ch2 or ChannelWaveformConfig(waveform_type=config.mode),
            "ch3": config.ch3 or ChannelWaveformConfig(waveform_type="off"),
            "ch4": config.ch4 or ChannelWaveformConfig(waveform_type="off"),
            "ch5": config.ch5 or ChannelWaveformConfig(waveform_type="off"),
            "ch6": config.ch6 or ChannelWaveformConfig(waveform_type="off"),
            "ch7": config.ch7 or ChannelWaveformConfig(waveform_type="off"),
            "ch8": config.ch8 or ChannelWaveformConfig(waveform_type="off"),
        }
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
            *(f"{CHANNEL_LABELS[channel]}: {_summarize_channel(channel_config)}" for channel, channel_config in channel_configs.items()),
        ]
    )


def _summarize_channel(config: ChannelWaveformConfig) -> str:
    waveform_type = config.waveform_type.lower()
    if waveform_type == "quantum":
        return f"quantum {config.quantum_gate.lower()}"
    if waveform_type == "iq-sine":
        return f"IQ sine {config.freq_hz:g} Hz"
    if waveform_type == "sine":
        return f"sine {config.freq_hz:g} Hz"
    if waveform_type == "burst":
        return f"burst {config.freq_hz:g} Hz delay={config.delay_s:g}s duration={config.duration_s:g}s"
    if waveform_type == "ezq-xy":
        return f"ez-Q XY {config.freq_hz:g} Hz"
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


def build_ila_report_command(config: IlaReportConfig, connection: ConnectionConfig) -> list[str]:
    command = [
        sys.executable,
        str(ILA_CAPTURE_REPORT_SCRIPT),
        "--capture",
        "--send-after-arm",
        "--artifact-dir",
        str(config.artifact_dir),
        "--bit",
        str(config.bitstream_path),
        "--ltx",
        str(config.ltx_path),
        "--out-dir",
        str(config.output_dir),
        "--udp-interface",
        connection.udp_interface,
        "--udp-source-ip",
        connection.udp_source_ip,
        "--ip",
        connection.ip,
        "--port",
        str(connection.port),
        "--timeout-s",
        f"{connection.timeout_s:g}",
        "--post-upload-sleep-s",
        str(connection.post_upload_sleep_s),
        "--program-mode",
        config.program_mode,
    ]
    if config.program_mode in {"auto", "always"}:
        command.append("--yes")
    return command


def build_ila_capture_command(config: IlaReportConfig, connection: ConnectionConfig) -> list[str]:
    return build_ila_report_command(config, connection)


def _run_ila_subprocess(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=SOFTWARE_DIR.parent, text=True, capture_output=True, check=False)


def run_ila_capture_report(
    config: IlaReportConfig,
    connection: ConnectionConfig,
    runner: IlaSubprocessRunner = _run_ila_subprocess,
) -> IlaReportResult:
    command = build_ila_capture_command(config, connection)
    completed = runner(command)
    stdout_values = _parse_key_value_lines(completed.stdout)
    stderr_values = _parse_key_value_lines(completed.stderr)
    overall_status = stdout_values.get("overall_status") or stderr_values.get("overall_status") or "UNKNOWN"
    markdown_report = _optional_path(stdout_values.get("markdown_report") or stderr_values.get("markdown_report"))
    json_report = _optional_path(stdout_values.get("json_report") or stderr_values.get("json_report"))
    log_lines = _build_ila_log_lines(completed.returncode, overall_status, markdown_report, json_report, completed.stdout, completed.stderr)
    return IlaReportResult(
        ok=completed.returncode == 0,
        returncode=completed.returncode,
        overall_status=overall_status,
        markdown_report=markdown_report,
        json_report=json_report,
        stdout=completed.stdout,
        stderr=completed.stderr,
        command=command,
        log_lines=log_lines,
    )


def _parse_key_value_lines(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        key, separator, value = line.partition("=")
        if separator:
            values[key.strip()] = value.strip()
    return values


def _optional_path(value: str | None) -> Path | None:
    if not value:
        return None
    return Path(value)


def _build_ila_log_lines(
    returncode: int,
    overall_status: str,
    markdown_report: Path | None,
    json_report: Path | None,
    stdout: str,
    stderr: str,
) -> list[str]:
    log_lines = [f"ila status: {overall_status}", f"overall_status={overall_status}"]
    if markdown_report is not None:
        log_lines.append(f"ila report: {markdown_report}")
        log_lines.append(f"markdown_report={markdown_report}")
    if json_report is not None:
        log_lines.append(f"ila json: {json_report}")
        log_lines.append(f"json_report={json_report}")
    if returncode != 0:
        log_lines.append(f"ila subprocess exit: {returncode}")
        log_lines.extend(f"stdout: {line}" for line in _tail_nonempty_lines(stdout))
        log_lines.extend(f"stderr: {line}" for line in _tail_nonempty_lines(stderr))
    return log_lines


def channel_delay_cycles(config: WaveformConfig) -> dict[int, int]:
    if config.ddr_layout == host.DDR_LAYOUT_INTERLEAVED_512B:
        return {}
    if any(channel is not None for channel in (config.ch1, config.ch2, config.ch3, config.ch4, config.ch5, config.ch6, config.ch7, config.ch8)):
        channel_configs = {
            1: config.ch1,
            2: config.ch2,
            3: config.ch3,
            4: config.ch4,
            5: config.ch5,
            6: config.ch6,
            7: config.ch7,
            8: config.ch8,
        }
        return {
            channel: waveform_tools.delay_seconds_to_axis_cycles_by_freq(channel_config.delay_s, config.axis_freq_hz)
            for channel, channel_config in channel_configs.items()
            if channel_config is not None and channel_config.waveform_type.lower() != "off"
        }
    if config.mode.lower() == "ezq-quantum":
        return {
            channel: waveform_tools.delay_seconds_to_axis_cycles_by_freq(
                _ezq_effective_channel_config(config.ezq, channel).timing_lag_xy_s,
                config.axis_freq_hz,
            )
            for channel in range(1, 9)
            if _ezq_effective_channel_config(config.ezq, channel).enabled
        }
    if config.mode.lower() == "burst":
        return {
            1: waveform_tools.delay_seconds_to_axis_cycles_by_freq(config.x_delay_s, config.axis_freq_hz),
            2: waveform_tools.delay_seconds_to_axis_cycles_by_freq(config.y_delay_s, config.axis_freq_hz),
        }
    return {}


def ezq_channel_sequences(generated: GeneratedWaveforms) -> dict[int, np.ndarray]:
    sequences: dict[int, np.ndarray] = {}
    waves = {
        1: generated.ch1,
        2: generated.ch2,
        3: generated.ch3,
        4: generated.ch4,
        5: generated.ch5,
        6: generated.ch6,
        7: generated.ch7,
        8: generated.ch8,
    }
    for channel, wave in waves.items():
        meta = generated.metadata.get(f"ch{channel}")
        if not isinstance(meta, dict):
            meta = {}
        interleaved_words = int(np.asarray(wave, dtype=np.int16).size)
        length_units = max(1, interleaved_words // 4)
        delay_cycles = int(meta.get("delay_cycles", generated.metadata.get(f"ch{channel}_delay_cycles", 0)))
        sequences[channel] = np.array(
            [
                [0, length_units, delay_cycles, 4 << 11],
                [0, length_units, 0, 0x0000],
                [0, 0, 0, 0x8000],
            ],
            dtype="<u2",
        )
    return sequences


def _tail_nonempty_lines(text: str, limit: int = 6) -> list[str]:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return lines[-limit:]


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
            extra_channels={5: generated.ch5, 6: generated.ch6, 7: generated.ch7, 8: generated.ch8},
        )
        waveform_tools.save_ezq_wave_bundle(
            output_dir,
            {
                1: generated.ch1,
                2: generated.ch2,
                3: generated.ch3,
                4: generated.ch4,
                5: generated.ch5,
                6: generated.ch6,
                7: generated.ch7,
                8: generated.ch8,
            },
            generated.metadata,
            channel_sequences=ezq_channel_sequences(generated),
            channel_format="interleaved_iq",
            stem="ezq",
        )

        log_lines = [
            "progress: generated waveforms",
            f"mode={config.mode} sample_rate_hz={config.sample_rate_hz:g}",
            summarize_waveform("X", generated.x),
            summarize_waveform("Y", generated.y),
            summarize_waveform("CH3", generated.ch3),
            summarize_waveform("CH4", generated.ch4),
            summarize_waveform("CH5", generated.ch5),
            summarize_waveform("CH6", generated.ch6),
            summarize_waveform("CH7", generated.ch7),
            summarize_waveform("CH8", generated.ch8),
            "progress: saved artifacts",
            "progress: saved ezq artifacts",
            f"saved artifacts to {output_dir}",
        ]
        if config.dry_run:
            log_lines.append("dry-run: not sending UDP packets")
            log_lines.append("progress: dry-run complete")
            return ControllerResult(generated=generated, output_dir=output_dir, dry_run=True, log_lines=log_lines)

        log_lines.append("progress: sending UDP packets")
        per_channel_nco = generated.metadata.get("per_channel_nco")
        per_channel_zone = generated.metadata.get("per_channel_zone")
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
            loop=False,
            auto_start=not config.wait_for_trigger,
            ch3=generated.ch3,
            ch4=generated.ch4,
            extra_channels={5: generated.ch5, 6: generated.ch6, 7: generated.ch7, 8: generated.ch8},
            channel_delays=channel_delay_cycles(config),
            layout=config.ddr_layout,
            rfdc_nco_hz=per_channel_nco if isinstance(per_channel_nco, dict) else None,
            rfdc_nyquist_zones=per_channel_zone if isinstance(per_channel_zone, dict) else None,
        )
        log_lines.append("progress: send complete")
        log_lines.append(f"sent UDP waveform to {connection.ip}:{connection.port}")
        return ControllerResult(generated=generated, output_dir=output_dir, dry_run=False, log_lines=log_lines)
