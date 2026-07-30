#!/usr/bin/env python3
"""Tkinter entrypoint for the RFSoC X/Y waveform sender."""

from __future__ import annotations

import argparse
import queue
import shlex
import sys
import threading
import tkinter as tk
from dataclasses import replace
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from typing import Any, cast

import host
import waveform_gui_model as model
import waveform_gui_view as view


CHANNELS = ("ch1", "ch2", "ch3", "ch4", "ch5", "ch6", "ch7", "ch8")
PREVIEW_TITLES = (
    "CH1 XY lane0 vout00",
    "CH2 XY lane1 vout02",
    "CH3 XY lane2 vout10",
    "CH4 XY lane3 vout12",
    "CH5 Z lane4 vout20",
    "CH6 Z lane5 vout22",
    "CH7 Readout lane6 vout30",
    "CH8 Readout lane7 vout32",
)
CHANNEL_PANEL_TITLES = dict(zip(CHANNELS, PREVIEW_TITLES, strict=True))
PREVIEW_COLORS = ("#38bdf8", "#f97316", "#22c55e", "#e879f9", "#a78bfa", "#facc15", "#14b8a6", "#fb7185")
COLOR_BACKGROUND = "#0f172a"
COLOR_CARD = "#172033"
COLOR_TEXT = "#dbeafe"
COLOR_TEXT_STRONG = "#f8fafc"
COLOR_TEXT_MUTED = "#94a3b8"
COLOR_ACCENT = "#38bdf8"
COLOR_ACCENT_ACTIVE = "#7dd3fc"
COLOR_ACCENT_TEXT = "#082f49"
COLOR_INPUT_BACKGROUND = "#e2e8f0"
COLOR_INPUT_TEXT = "#0f172a"
COLOR_DISABLED_TEXT = "#64748b"
COLOR_LOG_BACKGROUND = "#020617"


WAVEFORM_TYPES = ("dc-iq-cw", "iq-sine", "iq-gaussian-sine")
DEFAULT_CHANNEL_WAVEFORM_TYPE = "dc-iq-cw"
WAVEFORM_TYPE_LABELS = {
    "dc-iq-cw": "IQ CW",
    "iq-sine": "IQ Sine",
    "iq-gaussian-sine": "IQ Gaussian Sine",
}
ACTION_BUTTONS = ("Preview", "Test Connection", "Save / Dry Run", "Send to Board")
ACTION_BUTTON_GRID_COLUMNS = 2
ACTION_BUTTON_GRID_STICKY = "ew"
ACTION_BUTTON_MIN_WIDTH_PX = 180
CONTROL_PANEL_WIDTH_PX = 420
WINDOW_MIN_WIDTH_PX = 1020
WINDOW_MIN_HEIGHT_PX = 680
SEND_CONFIRMATION_TITLE = "Confirm send to board"
GLOBAL_SAMPLE_RATE_LABEL = "IQ sample rate (GS/s)"
GLOBAL_RFDC_INTERPOLATION_LABEL = "RFDC interpolation (x)"
GLOBAL_AXIS_FREQ_LABEL = "AXIS clock (MHz)"
ILA_CAPTURE_BUTTON_TEXT = "Run ILA Capture + Report"
EXTREME_TEST_BUTTON_TEXT = "Run Extreme Test"
ILA_PROGRAM_MODES = ("never", "auto", "always")
DEFAULT_ILA_PROGRAM_MODE = "never"
CONTROL_TABS = ("Setup", "Quantum", "Channels", "ILA Report")
WAVEFORM_SOURCE_MODES = ("ezq-quantum", "manual-channels")
WAVEFORM_SOURCE_LABELS = {
    "ezq-quantum": "ez-Q Quantum Pulse",
    "manual-channels": "Manual CH1-CH8",
}
EZQ_CHANNEL_WAVEFORMS = ("xy", "z", "readout")
EZQ_XY_GATES = ("x_pi", "y_pi", "x_half", "y_half", "x12_pi", "x12_half", "spec")
EZQ_Z_SHAPES = ("square", "diabatic_cz")

CHANNEL_FIELD_GROUPS = {
    "dc-iq-cw": ("amplitude", "duration_s"),
    "iq-sine": ("freq_hz", "phase_rad", "amplitude", "duration_s"),
    "iq-gaussian-sine": ("freq_hz", "phase_rad", "amplitude", "duration_s"),
}

CONTROL_SCROLLBAR_MARKERS = ("tk.Canvas", "ttk.Scrollbar", "yscrollcommand", "<MouseWheel>")
CONTROL_TAB_MARKERS = ("ttk.Notebook",) + CONTROL_TABS
COMBOBOX_WHEEL_BLOCK_EVENTS = ("<MouseWheel>", "<Button-4>", "<Button-5>")

LABELS = {
    "freq_hz": "IQ sine freq (MHz)",
    "phase_rad": "Phase (rad)",
    "amplitude": "Amplitude (DAC codes)",
    "duration_s": "Length (ns)",
}

EZQ_FIELD_UNITS = {
    "f10_hz": "mhz",
    "f21_hz": "mhz",
    "fc_hz": "mhz",
    "nonlinearity_hz": "mhz",
    "pi_df_hz": "mhz",
    "target_rf_hz": "mhz",
    "detune_hz": "mhz",
    "readout_freq_hz": "mhz",
    "readout_fc_hz": "mhz",
    "pi_len_s": "ns",
    "pi_fwhm_s": "ns",
    "pi_len_half_s": "ns",
    "pi_fwhm_half_s": "ns",
    "pi_len_z_s": "ns",
    "z_shape": "text",
    "z_start_s": "ns",
    "z_gate_time_s": "ns",
    "z_edge_s": "ns",
    "readout_len_s": "ns",
    "readout_edge_s": "ns",
    "readout_flattop_s": "ns",
    "z_len_s": "ns",
    "spec_len_s": "ns",
    "ring_len_s": "ns",
    "readout_start_s": "ns",
    "adc_start_delay_s": "ns",
    "timing_lag_xy_s": "ns",
    "timing_lag_z_s": "ns",
    "timing_lag_read_s": "ns",
    "start_time_s": "ns",
    "record_duration_s": "ns",
    "period_s": "ns",
}

EZQ_PARAMETER_SECTIONS = (
    view.SectionSpec(
        "Qubit Profile",
        (
            view.FieldSpec("f10 (MHz)", "f10_hz"),
            view.FieldSpec("f21 (MHz)", "f21_hz"),
            view.FieldSpec("fc / NCO center (MHz)", "fc_hz"),
            view.FieldSpec("nonlinearity delta (MHz)", "nonlinearity_hz"),
            view.FieldSpec("uwave_power (dBm)", "uwave_power_dbm"),
            view.FieldSpec("uwave_phase (rad)", "uwave_phase_rad"),
            view.FieldSpec("pi_df (MHz)", "pi_df_hz"),
            view.FieldSpec("xy_phase (rad)", "xy_phase_rad"),
        ),
    ),
    view.SectionSpec(
        "XY Gate Presets",
        (
            view.FieldSpec("pi_amp (-1..1)", "pi_amp"),
            view.FieldSpec("pi_len (ns)", "pi_len_s"),
            view.FieldSpec("pi_fwhm (ns)", "pi_fwhm_s"),
            view.FieldSpec("pi_alpha / DRAG", "pi_alpha"),
            view.FieldSpec("pi_amp_half", "pi_amp_half"),
            view.FieldSpec("pi_len_half (ns)", "pi_len_half_s"),
            view.FieldSpec("pi_fwhm_half (ns)", "pi_fwhm_half_s"),
            view.FieldSpec("pi_alpha_half", "pi_alpha_half"),
            view.FieldSpec("pi_amp21", "pi_amp21"),
            view.FieldSpec("pi_amp21_half", "pi_amp21_half"),
            view.FieldSpec("spec_amp", "spec_amp"),
            view.FieldSpec("spec_len (ns)", "spec_len_s"),
        ),
    ),
    view.SectionSpec(
        "Z Gate Preset",
        (
            view.FieldSpec("z_offset", "z_offset"),
            view.FieldSpec("pi_amp_z", "pi_amp_z"),
            view.FieldSpec("pi_len_z (ns)", "pi_len_z_s"),
            view.FieldSpec("z_gate_time (ns)", "z_gate_time_s"),
            view.FieldSpec("z_edge (ns)", "z_edge_s"),
        ),
    ),
    view.SectionSpec(
        "Readout Preset",
        (
            view.FieldSpec("readout_freq (MHz)", "readout_freq_hz"),
            view.FieldSpec("readout_fc (MHz)", "readout_fc_hz"),
            view.FieldSpec("readout_len (ns)", "readout_len_s"),
            view.FieldSpec("readout_start (ns)", "readout_start_s"),
            view.FieldSpec("readout_edge (ns)", "readout_edge_s"),
            view.FieldSpec("readout_flattop (ns)", "readout_flattop_s"),
            view.FieldSpec("readout_zpa", "readout_zpa"),
            view.FieldSpec("readout_power (dBm)", "readout_power_dbm"),
            view.FieldSpec("ring_power (dBm)", "ring_power_dbm"),
            view.FieldSpec("readout_uwave_power (dBm)", "readout_uwave_power_dbm"),
            view.FieldSpec("ring_len (ns)", "ring_len_s"),
        ),
    ),
    view.SectionSpec(
        "Timing / Channels",
        (
            view.FieldSpec("record duration (ns)", "record_duration_s"),
            view.FieldSpec("adc_start_delay (ns)", "adc_start_delay_s"),
            view.FieldSpec("timing_lag_xy (ns)", "timing_lag_xy_s"),
            view.FieldSpec("timing_lag_z (ns)", "timing_lag_z_s"),
            view.FieldSpec("timing_lag_read (ns)", "timing_lag_read_s"),
            view.FieldSpec("repeat", "repeat"),
            view.FieldSpec("period (ns)", "period_s"),
        ),
    ),
)

EZQ_CHANNEL_COMMON_FIELDS = (
    view.FieldSpec("Start time (ns)", "start_time_s"),
)

EZQ_CHANNEL_XY_GATE_FIELD = view.FieldSpec("XY Gate", "xy_gate")
EZQ_CHANNEL_XY_GATE_FIELDS = {
    "x_pi": (
        view.FieldSpec("target RF / NCO (MHz)", "target_rf_hz"),
        view.FieldSpec("detune / IQ offset (MHz)", "detune_hz"),
        view.FieldSpec("f10 (MHz)", "f10_hz"),
        view.FieldSpec("fc (MHz)", "fc_hz"),
        view.FieldSpec("pi_df (MHz)", "pi_df_hz"),
        view.FieldSpec("pi_amp (-1..1)", "pi_amp"),
        view.FieldSpec("pi_len (ns)", "pi_len_s"),
        view.FieldSpec("pi_fwhm (ns)", "pi_fwhm_s"),
        view.FieldSpec("pi_alpha", "pi_alpha"),
        view.FieldSpec("nonlinearity (MHz)", "nonlinearity_hz"),
        view.FieldSpec("xy_phase (rad)", "xy_phase_rad"),
    ),
    "y_pi": (
        view.FieldSpec("target RF / NCO (MHz)", "target_rf_hz"),
        view.FieldSpec("detune / IQ offset (MHz)", "detune_hz"),
        view.FieldSpec("f10 (MHz)", "f10_hz"),
        view.FieldSpec("fc (MHz)", "fc_hz"),
        view.FieldSpec("pi_df (MHz)", "pi_df_hz"),
        view.FieldSpec("pi_amp (-1..1)", "pi_amp"),
        view.FieldSpec("pi_len (ns)", "pi_len_s"),
        view.FieldSpec("pi_fwhm (ns)", "pi_fwhm_s"),
        view.FieldSpec("pi_alpha", "pi_alpha"),
        view.FieldSpec("nonlinearity (MHz)", "nonlinearity_hz"),
        view.FieldSpec("xy_phase (rad)", "xy_phase_rad"),
    ),
    "x_half": (
        view.FieldSpec("target RF / NCO (MHz)", "target_rf_hz"),
        view.FieldSpec("detune / IQ offset (MHz)", "detune_hz"),
        view.FieldSpec("f10 (MHz)", "f10_hz"),
        view.FieldSpec("fc (MHz)", "fc_hz"),
        view.FieldSpec("pi_df (MHz)", "pi_df_hz"),
        view.FieldSpec("pi_amp_half", "pi_amp_half"),
        view.FieldSpec("pi_len_half (ns)", "pi_len_half_s"),
        view.FieldSpec("pi_fwhm_half (ns)", "pi_fwhm_half_s"),
        view.FieldSpec("pi_alpha_half", "pi_alpha_half"),
        view.FieldSpec("nonlinearity (MHz)", "nonlinearity_hz"),
        view.FieldSpec("xy_phase (rad)", "xy_phase_rad"),
    ),
    "y_half": (
        view.FieldSpec("target RF / NCO (MHz)", "target_rf_hz"),
        view.FieldSpec("detune / IQ offset (MHz)", "detune_hz"),
        view.FieldSpec("f10 (MHz)", "f10_hz"),
        view.FieldSpec("fc (MHz)", "fc_hz"),
        view.FieldSpec("pi_df (MHz)", "pi_df_hz"),
        view.FieldSpec("pi_amp_half", "pi_amp_half"),
        view.FieldSpec("pi_len_half (ns)", "pi_len_half_s"),
        view.FieldSpec("pi_fwhm_half (ns)", "pi_fwhm_half_s"),
        view.FieldSpec("pi_alpha_half", "pi_alpha_half"),
        view.FieldSpec("nonlinearity (MHz)", "nonlinearity_hz"),
        view.FieldSpec("xy_phase (rad)", "xy_phase_rad"),
    ),
    "x12_pi": (
        view.FieldSpec("target RF / NCO (MHz)", "target_rf_hz"),
        view.FieldSpec("detune / IQ offset (MHz)", "detune_hz"),
        view.FieldSpec("f21 (MHz)", "f21_hz"),
        view.FieldSpec("fc (MHz)", "fc_hz"),
        view.FieldSpec("pi_df (MHz)", "pi_df_hz"),
        view.FieldSpec("pi_amp21", "pi_amp21"),
        view.FieldSpec("pi_len (ns)", "pi_len_s"),
        view.FieldSpec("pi_fwhm (ns)", "pi_fwhm_s"),
        view.FieldSpec("pi_alpha", "pi_alpha"),
        view.FieldSpec("nonlinearity (MHz)", "nonlinearity_hz"),
        view.FieldSpec("xy_phase (rad)", "xy_phase_rad"),
    ),
    "x12_half": (
        view.FieldSpec("target RF / NCO (MHz)", "target_rf_hz"),
        view.FieldSpec("detune / IQ offset (MHz)", "detune_hz"),
        view.FieldSpec("f21 (MHz)", "f21_hz"),
        view.FieldSpec("fc (MHz)", "fc_hz"),
        view.FieldSpec("pi_df (MHz)", "pi_df_hz"),
        view.FieldSpec("pi_amp21_half", "pi_amp21_half"),
        view.FieldSpec("pi_len_half (ns)", "pi_len_half_s"),
        view.FieldSpec("pi_fwhm_half (ns)", "pi_fwhm_half_s"),
        view.FieldSpec("pi_alpha_half", "pi_alpha_half"),
        view.FieldSpec("nonlinearity (MHz)", "nonlinearity_hz"),
        view.FieldSpec("xy_phase (rad)", "xy_phase_rad"),
    ),
    "spec": (
        view.FieldSpec("target RF / NCO (MHz)", "target_rf_hz"),
        view.FieldSpec("detune / IQ offset (MHz)", "detune_hz"),
        view.FieldSpec("f10 (MHz)", "f10_hz"),
        view.FieldSpec("fc (MHz)", "fc_hz"),
        view.FieldSpec("pi_df (MHz)", "pi_df_hz"),
        view.FieldSpec("spec_amp", "spec_amp"),
        view.FieldSpec("spec_len (ns)", "spec_len_s"),
        view.FieldSpec("xy_phase (rad)", "xy_phase_rad"),
    ),
}

EZQ_CHANNEL_XY_FIELDS = (
    view.FieldSpec("XY Gate", "xy_gate"),
    view.FieldSpec("target RF / NCO (MHz)", "target_rf_hz"),
    view.FieldSpec("detune / IQ offset (MHz)", "detune_hz"),
    view.FieldSpec("f10 (MHz)", "f10_hz"),
    view.FieldSpec("f21 (MHz)", "f21_hz"),
    view.FieldSpec("fc (MHz)", "fc_hz"),
    view.FieldSpec("nonlinearity (MHz)", "nonlinearity_hz"),
    view.FieldSpec("pi_df (MHz)", "pi_df_hz"),
    view.FieldSpec("pi_amp (-1..1)", "pi_amp"),
    view.FieldSpec("pi_len (ns)", "pi_len_s"),
    view.FieldSpec("pi_fwhm (ns)", "pi_fwhm_s"),
    view.FieldSpec("pi_alpha", "pi_alpha"),
    view.FieldSpec("pi_amp_half", "pi_amp_half"),
    view.FieldSpec("pi_len_half (ns)", "pi_len_half_s"),
    view.FieldSpec("pi_fwhm_half (ns)", "pi_fwhm_half_s"),
    view.FieldSpec("pi_alpha_half", "pi_alpha_half"),
    view.FieldSpec("pi_amp21", "pi_amp21"),
    view.FieldSpec("pi_amp21_half", "pi_amp21_half"),
    view.FieldSpec("spec_amp", "spec_amp"),
    view.FieldSpec("spec_len (ns)", "spec_len_s"),
    view.FieldSpec("xy_phase (rad)", "xy_phase_rad"),
)

EZQ_CHANNEL_Z_BASE_FIELDS = (
    view.FieldSpec("Z Shape", "z_shape"),
    view.FieldSpec("z_amp (-1..1)", "z_amp"),
    view.FieldSpec("z_gate_time (ns)", "z_gate_time_s"),
    view.FieldSpec("z_edge (ns)", "z_edge_s"),
    view.FieldSpec("z_len (ns)", "z_len_s"),
)

EZQ_CHANNEL_Z_RIPPLE_FIELDS = (
    view.FieldSpec("z_ripple0", "z_ripple0"),
    view.FieldSpec("z_ripple1", "z_ripple1"),
    view.FieldSpec("z_ripple2", "z_ripple2"),
    view.FieldSpec("z_ripple3", "z_ripple3"),
)

EZQ_CHANNEL_Z_FIELDS = EZQ_CHANNEL_Z_BASE_FIELDS + EZQ_CHANNEL_Z_RIPPLE_FIELDS

EZQ_CHANNEL_READOUT_FIELDS = (
    view.FieldSpec("target RF / NCO (MHz)", "target_rf_hz"),
    view.FieldSpec("detune / IQ offset (MHz)", "detune_hz"),
    view.FieldSpec("readout_freq fallback (MHz)", "readout_freq_hz"),
    view.FieldSpec("readout_amp (-1..1)", "readout_amp"),
    view.FieldSpec("readout_len (ns)", "readout_len_s"),
    view.FieldSpec("readout_edge (ns)", "readout_edge_s"),
    view.FieldSpec("readout_flattop (ns)", "readout_flattop_s"),
    view.FieldSpec("readout_zpa", "readout_zpa"),
    view.FieldSpec("readout_phase (rad)", "readout_phase_rad"),
)

EZQ_CHANNEL_FIELD_GROUPS = {
    "xy": EZQ_CHANNEL_COMMON_FIELDS + EZQ_CHANNEL_XY_FIELDS,
    "z": EZQ_CHANNEL_COMMON_FIELDS + EZQ_CHANNEL_Z_FIELDS,
    "readout": EZQ_CHANNEL_COMMON_FIELDS + EZQ_CHANNEL_READOUT_FIELDS,
}


def _ezq_xy_gate_fields(gate: str) -> tuple[view.FieldSpec, ...]:
    return EZQ_CHANNEL_COMMON_FIELDS + (EZQ_CHANNEL_XY_GATE_FIELD,) + EZQ_CHANNEL_XY_GATE_FIELDS.get(gate, EZQ_CHANNEL_XY_GATE_FIELDS["x_pi"])


def _ezq_z_shape_fields(shape: str) -> tuple[view.FieldSpec, ...]:
    if shape == "diabatic_cz":
        return EZQ_CHANNEL_COMMON_FIELDS + EZQ_CHANNEL_Z_BASE_FIELDS + EZQ_CHANNEL_Z_RIPPLE_FIELDS
    return EZQ_CHANNEL_COMMON_FIELDS + EZQ_CHANNEL_Z_BASE_FIELDS


def _field_display_label(field_name: str) -> str:
    return LABELS[field_name]


def _gui_waveform_type(value: str | None) -> str:
    normalized = str(value or "").lower()
    if normalized == "sine":
        return "iq-sine"
    if normalized in {"pypulse", "burst", "hls", "iq-gaussian"}:
        return "iq-gaussian-sine"
    if normalized in WAVEFORM_TYPES:
        return normalized
    return DEFAULT_CHANNEL_WAVEFORM_TYPE


def _block_combobox_mousewheel(_event: object) -> str:
    return "break"


def _format_display_value(value: float) -> str:
    return f"{value:g}"


def to_display_mhz(value_hz: float) -> str:
    return _format_display_value(float(value_hz) / 1e6)


def from_display_mhz(value_mhz: str) -> float:
    return float(value_mhz) * 1e6


def to_display_ns(value_s: float) -> str:
    return _format_display_value(float(value_s) / 1e-9)


def from_display_ns(value_ns: str) -> float:
    return float(value_ns) / 1e9


def to_display_gsps(value_hz: float) -> str:
    return _format_display_value(float(value_hz) / 1e9)


def from_display_gsps(value_gsps: str) -> float:
    return float(value_gsps) * 1e9


class DebouncedPreviewBinder:
    def __init__(self, scheduler: Any, variables: list[Any], callback: Any, delay_ms: int = 250):
        self.scheduler = scheduler
        self.callback = callback
        self.delay_ms = delay_ms
        self.pending_after_id: str | None = None
        self.trace_ids = [variable.trace_add("write", self.schedule) for variable in variables]

    def schedule(self, *_args: object) -> None:
        if self.pending_after_id is not None:
            self.scheduler.after_cancel(self.pending_after_id)
        self.pending_after_id = self.scheduler.after(self.delay_ms, self._run)

    def _run(self) -> None:
        self.pending_after_id = None
        self.callback()


class AutoSaveBinder(DebouncedPreviewBinder):
    pass


class WaveformSenderApp(ttk.Frame):
    def __init__(self, master: tk.Tk):
        super().__init__(master, padding=18)
        self.root = master
        self.controller = model.WaveformController()
        self.messages: queue.Queue[tuple[str, object]] = queue.Queue()
        self.settings_path = model.DEFAULT_GUI_SETTINGS_PATH
        self._settings_loaded = False
        self._preview_binder: DebouncedPreviewBinder | None = None
        self._autosave_binder: AutoSaveBinder | None = None
        self._build_variables()
        self._configure_style()
        self._build_widgets()
        for channel in CHANNELS:
            self._set_channel_fields(channel)
        self._preview_binder = DebouncedPreviewBinder(self, self._preview_variables(), self._preview_from_live_edit)
        self._autosave_binder = AutoSaveBinder(self, self._settings_variables(), self._save_settings_from_live_edit, delay_ms=600)
        self.preview_waveforms()
        self.after(100, self._drain_messages)

    def _build_variables(self) -> None:
        settings = model.load_gui_settings(self.settings_path)
        settings_exists = self.settings_path.exists()
        defaults = settings.waveform
        connection = settings.connection
        self.output_dir = tk.StringVar(value=str(defaults.output_dir))
        self.ip = tk.StringVar(value=connection.ip)
        self.port = tk.StringVar(value=str(connection.port))
        self.udp_interface = tk.StringVar(value=connection.udp_interface)
        self.udp_source_ip = tk.StringVar(value=connection.udp_source_ip)
        self.timeout_s = tk.StringVar(value=str(connection.timeout_s))
        self.post_upload_sleep_s = tk.StringVar(value=str(connection.post_upload_sleep_s))
        self.sample_rate_hz = tk.StringVar(value=to_display_gsps(defaults.sample_rate_hz))
        self.rfdc_interpolation = tk.StringVar(value=str(defaults.rfdc_interpolation))
        self.axis_freq_hz = tk.StringVar(value=to_display_mhz(defaults.axis_freq_hz))
        default_source = "ezq-quantum" if defaults.mode == "ezq-quantum" or not settings_exists else "manual-channels"
        self.waveform_source = tk.StringVar(value=default_source)
        self.loop = tk.BooleanVar(value=defaults.loop)
        self.wait_for_trigger = tk.BooleanVar(value=defaults.wait_for_trigger)
        self.dry_run = tk.BooleanVar(value=defaults.dry_run)
        self.extreme_bytes_per_channel = tk.StringVar(value="max")
        self.extreme_pattern = tk.StringVar(value=host.MAX_LENGTH_PATTERN_LOWFREQ_SINE)
        self.extreme_sine_freq_hz = tk.StringVar(value="10")
        self.extreme_sine_amplitude = tk.StringVar(value="4096")
        self.extreme_beats_per_datagram = tk.StringVar(value=str(host.DEFAULT_UDP_BULK_BEATS))
        self.extreme_marker_bytes_per_channel = tk.StringVar(value="4096")
        self.extreme_use_waveform_cache = tk.BooleanVar(value=True)
        self.extreme_force_waveform_cache = tk.BooleanVar(value=False)
        self.ezq_fields = self._make_ezq_field_variables(defaults.ezq)
        self.ezq_channel_fields = self._make_ezq_channel_field_variables(defaults.ezq)
        self.ezq_channel_enabled = {
            channel: tk.BooleanVar(value=self._effective_ezq_channel(defaults.ezq, index + 1).enabled)
            for index, channel in enumerate(CHANNELS)
        }
        self.ezq_channel_waveform = {
            channel: tk.StringVar(value=self._effective_ezq_channel(defaults.ezq, index + 1).waveform)
            for index, channel in enumerate(CHANNELS)
        }
        ila_defaults = settings.ila
        self.ila_bitstream_path = tk.StringVar(value=str(ila_defaults.bitstream_path))
        self.ila_ltx_path = tk.StringVar(value=str(ila_defaults.ltx_path))
        self.ila_report_dir = tk.StringVar(value=str(ila_defaults.output_dir))
        self.ila_program_mode = tk.StringVar(value=ila_defaults.program_mode)
        channel_defaults = {channel: getattr(defaults, channel) for channel in CHANNELS}
        def channel_waveform_type(channel: str) -> str:
            channel_config = channel_defaults[channel]
            if channel_config is not None:
                return _gui_waveform_type(channel_config.waveform_type)
            return _gui_waveform_type(defaults.mode)

        self.channel_type = {
            channel: tk.StringVar(value=channel_waveform_type(channel)) for channel in CHANNELS
        }
        self.channel_enabled = {
            channel: tk.BooleanVar(
                value=channel_defaults[channel] is None or str(channel_defaults[channel].waveform_type).lower() != "off"
            )
            for channel in CHANNELS
        }
        def channel_fields(freq_hz: float, phase_rad: float) -> dict[str, tk.StringVar]:
            return {
                "freq_hz": tk.StringVar(value=to_display_mhz(freq_hz)),
                "phase_rad": tk.StringVar(value=f"{phase_rad:g}"),
                "amplitude": tk.StringVar(value=str(defaults.amplitude)),
                "duration_s": tk.StringVar(value=to_display_ns(defaults.duration_s)),
            }

        self.channel_fields = {
            "ch1": channel_fields(defaults.x_freq_hz, defaults.x_phase_rad),
            "ch2": channel_fields(defaults.y_freq_hz, defaults.y_phase_rad),
            "ch3": channel_fields(defaults.x_freq_hz, defaults.x_phase_rad),
            "ch4": channel_fields(defaults.y_freq_hz, defaults.y_phase_rad),
            "ch5": channel_fields(defaults.x_freq_hz, defaults.x_phase_rad),
            "ch6": channel_fields(defaults.y_freq_hz, defaults.y_phase_rad),
            "ch7": channel_fields(defaults.x_freq_hz, defaults.x_phase_rad),
            "ch8": channel_fields(defaults.y_freq_hz, defaults.y_phase_rad),
        }
        self._apply_channel_settings(defaults)
        self._settings_loaded = settings_exists

    def _make_ezq_field_variables(self, ezq: model.EzqPulseConfig) -> dict[str, tk.StringVar]:
        values = {
            "f10_hz": ezq.f10_hz,
            "f21_hz": ezq.f21_hz,
            "fc_hz": ezq.fc_hz,
            "uwave_power_dbm": ezq.uwave_power_dbm,
            "uwave_phase_rad": ezq.uwave_phase_rad,
            "nonlinearity_hz": ezq.nonlinearity_hz,
            "pi_amp": ezq.pi_amp,
            "pi_len_s": ezq.pi_len_s,
            "pi_fwhm_s": ezq.pi_fwhm_s,
            "pi_alpha": ezq.pi_alpha,
            "pi_amp_half": ezq.pi_amp_half,
            "pi_len_half_s": ezq.pi_len_half_s,
            "pi_fwhm_half_s": ezq.pi_fwhm_half_s,
            "pi_alpha_half": ezq.pi_alpha_half,
            "pi_amp21": ezq.pi_amp21,
            "pi_amp21_half": ezq.pi_amp21_half,
            "pi_df_hz": ezq.pi_df_hz,
            "xy_phase_rad": ezq.xy_phase_rad,
            "spec_amp": ezq.spec_amp,
            "spec_len_s": ezq.spec_len_s,
            "z_offset": ezq.z_offset,
            "pi_amp_z": ezq.pi_amp_z,
            "pi_len_z_s": ezq.pi_len_z_s,
            "z_shape": ezq.z_shape,
            "z_start_s": ezq.z_start_s,
            "z_gate_time_s": ezq.z_gate_time_s,
            "z_edge_s": ezq.z_edge_s,
            "z_ripple0": ezq.z_ripple0,
            "z_ripple1": ezq.z_ripple1,
            "z_ripple2": ezq.z_ripple2,
            "z_ripple3": ezq.z_ripple3,
            "readout_freq_hz": ezq.readout_freq_hz,
            "readout_fc_hz": ezq.readout_fc_hz,
            "readout_len_s": ezq.readout_len_s,
            "readout_edge_s": ezq.readout_edge_s,
            "readout_flattop_s": ezq.readout_flattop_s,
            "readout_zpa": ezq.readout_zpa,
            "readout_power_dbm": ezq.readout_power_dbm,
            "ring_power_dbm": ezq.ring_power_dbm,
            "readout_uwave_power_dbm": ezq.readout_uwave_power_dbm,
            "ring_len_s": ezq.ring_len_s,
            "readout_start_s": ezq.readout_start_s,
            "adc_start_delay_s": ezq.adc_start_delay_s,
            "timing_lag_xy_s": ezq.timing_lag_xy_s,
            "timing_lag_z_s": ezq.timing_lag_z_s,
            "timing_lag_read_s": ezq.timing_lag_read_s,
            "repeat": ezq.repeat,
            "period_s": ezq.period_s,
            "record_duration_s": ezq.record_duration_s,
        }
        return {key: tk.StringVar(value=self._format_ezq_display_value(key, value)) for key, value in values.items()}

    def _effective_ezq_channel(self, ezq: model.EzqPulseConfig, channel: int) -> model.EzqChannelConfig:
        channel_config = getattr(ezq, f"ch{channel}")
        role = host.CHANNEL_ROLES.get(channel, "xy")
        if channel_config is not None and str(channel_config.waveform).lower() == role:
            return channel_config
        if channel_config is not None and role == "readout":
            readout_target_hz = host.DEFAULT_READOUT_TARGET_RF_HZ.get(channel, ezq.readout_freq_hz)
            return replace(
                channel_config,
                waveform=role,
                target_rf_hz=readout_target_hz,
                readout_freq_hz=readout_target_hz,
                readout_fc_hz=readout_target_hz,
            )
        if channel_config is not None:
            return replace(channel_config, waveform=role)
        readout_target_hz = host.DEFAULT_READOUT_TARGET_RF_HZ.get(channel, ezq.readout_freq_hz)
        return model.EzqChannelConfig(
            enabled=bool(ezq.channel_mask & (1 << (channel - 1))),
            waveform=role,
            target_rf_hz=readout_target_hz if role == "readout" else 0.0,
            detune_hz=ezq.pi_df_hz if role == "xy" else 0.0,
            start_time_s=0.0,
            f10_hz=ezq.f10_hz,
            f21_hz=ezq.f21_hz,
            fc_hz=ezq.fc_hz,
            nonlinearity_hz=ezq.nonlinearity_hz,
            pi_amp=ezq.pi_amp,
            pi_len_s=ezq.pi_len_s,
            pi_fwhm_s=ezq.pi_fwhm_s,
            pi_alpha=ezq.pi_alpha,
            pi_amp_half=ezq.pi_amp_half,
            pi_len_half_s=ezq.pi_len_half_s,
            pi_fwhm_half_s=ezq.pi_fwhm_half_s,
            pi_alpha_half=ezq.pi_alpha_half,
            pi_amp21=ezq.pi_amp21,
            pi_amp21_half=ezq.pi_amp21_half,
            pi_df_hz=ezq.pi_df_hz,
            xy_phase_rad=ezq.xy_phase_rad,
            spec_amp=ezq.spec_amp,
            spec_len_s=ezq.spec_len_s,
            z_amp=ezq.pi_amp_z,
            z_len_s=ezq.pi_len_z_s,
            z_shape=ezq.z_shape,
            z_start_s=ezq.z_start_s,
            z_gate_time_s=ezq.z_gate_time_s,
            z_edge_s=ezq.z_edge_s,
            z_ripple0=ezq.z_ripple0,
            z_ripple1=ezq.z_ripple1,
            z_ripple2=ezq.z_ripple2,
            z_ripple3=ezq.z_ripple3,
            readout_freq_hz=readout_target_hz if role == "readout" else ezq.readout_freq_hz,
            readout_fc_hz=readout_target_hz if role == "readout" else ezq.readout_fc_hz,
            readout_len_s=ezq.readout_len_s,
            readout_start_s=ezq.readout_start_s,
            readout_edge_s=ezq.readout_edge_s,
            readout_flattop_s=ezq.readout_flattop_s,
            readout_zpa=ezq.readout_zpa,
            timing_lag_xy_s=ezq.timing_lag_xy_s,
            period_s=ezq.period_s,
        )

    def _make_ezq_channel_field_variables(self, ezq: model.EzqPulseConfig) -> dict[str, dict[str, tk.StringVar]]:
        variables: dict[str, dict[str, tk.StringVar]] = {}
        for index, channel in enumerate(CHANNELS, start=1):
            channel_config = self._effective_ezq_channel(ezq, index)
            variables[channel] = {
                "xy_gate": tk.StringVar(value=channel_config.xy_gate),
                "target_rf_hz": tk.StringVar(value=self._format_ezq_display_value("target_rf_hz", channel_config.target_rf_hz)),
                "detune_hz": tk.StringVar(value=self._format_ezq_display_value("detune_hz", channel_config.detune_hz)),
                "start_time_s": tk.StringVar(value=self._format_ezq_display_value("start_time_s", channel_config.start_time_s)),
                "f10_hz": tk.StringVar(value=self._format_ezq_display_value("f10_hz", channel_config.f10_hz)),
                "f21_hz": tk.StringVar(value=self._format_ezq_display_value("f21_hz", channel_config.f21_hz)),
                "fc_hz": tk.StringVar(value=self._format_ezq_display_value("fc_hz", channel_config.fc_hz)),
                "nonlinearity_hz": tk.StringVar(value=self._format_ezq_display_value("nonlinearity_hz", channel_config.nonlinearity_hz)),
                "pi_amp": tk.StringVar(value=self._format_ezq_display_value("pi_amp", channel_config.pi_amp)),
                "pi_len_s": tk.StringVar(value=self._format_ezq_display_value("pi_len_s", channel_config.pi_len_s)),
                "pi_fwhm_s": tk.StringVar(value=self._format_ezq_display_value("pi_fwhm_s", channel_config.pi_fwhm_s)),
                "pi_alpha": tk.StringVar(value=self._format_ezq_display_value("pi_alpha", channel_config.pi_alpha)),
                "pi_amp_half": tk.StringVar(value=self._format_ezq_display_value("pi_amp_half", channel_config.pi_amp_half)),
                "pi_len_half_s": tk.StringVar(value=self._format_ezq_display_value("pi_len_half_s", channel_config.pi_len_half_s)),
                "pi_fwhm_half_s": tk.StringVar(value=self._format_ezq_display_value("pi_fwhm_half_s", channel_config.pi_fwhm_half_s)),
                "pi_alpha_half": tk.StringVar(value=self._format_ezq_display_value("pi_alpha_half", channel_config.pi_alpha_half)),
                "pi_amp21": tk.StringVar(value=self._format_ezq_display_value("pi_amp21", channel_config.pi_amp21)),
                "pi_amp21_half": tk.StringVar(value=self._format_ezq_display_value("pi_amp21_half", channel_config.pi_amp21_half)),
                "pi_df_hz": tk.StringVar(value=self._format_ezq_display_value("pi_df_hz", channel_config.pi_df_hz)),
                "xy_phase_rad": tk.StringVar(value=self._format_ezq_display_value("xy_phase_rad", channel_config.xy_phase_rad)),
                "spec_amp": tk.StringVar(value=self._format_ezq_display_value("spec_amp", channel_config.spec_amp)),
                "spec_len_s": tk.StringVar(value=self._format_ezq_display_value("spec_len_s", channel_config.spec_len_s)),
                "z_amp": tk.StringVar(value=self._format_ezq_display_value("z_amp", channel_config.z_amp)),
                "z_len_s": tk.StringVar(value=self._format_ezq_display_value("z_len_s", channel_config.z_len_s)),
                "z_shape": tk.StringVar(value=channel_config.z_shape),
                "z_start_s": tk.StringVar(value=self._format_ezq_display_value("z_start_s", channel_config.z_start_s)),
                "z_gate_time_s": tk.StringVar(value=self._format_ezq_display_value("z_gate_time_s", channel_config.z_gate_time_s)),
                "z_edge_s": tk.StringVar(value=self._format_ezq_display_value("z_edge_s", channel_config.z_edge_s)),
                "z_ripple0": tk.StringVar(value=self._format_ezq_display_value("z_ripple0", channel_config.z_ripple0)),
                "z_ripple1": tk.StringVar(value=self._format_ezq_display_value("z_ripple1", channel_config.z_ripple1)),
                "z_ripple2": tk.StringVar(value=self._format_ezq_display_value("z_ripple2", channel_config.z_ripple2)),
                "z_ripple3": tk.StringVar(value=self._format_ezq_display_value("z_ripple3", channel_config.z_ripple3)),
                "readout_freq_hz": tk.StringVar(value=self._format_ezq_display_value("readout_freq_hz", channel_config.readout_freq_hz)),
                "readout_fc_hz": tk.StringVar(value=self._format_ezq_display_value("readout_fc_hz", channel_config.readout_fc_hz)),
                "readout_amp": tk.StringVar(value=self._format_ezq_display_value("readout_amp", channel_config.readout_amp)),
                "readout_len_s": tk.StringVar(value=self._format_ezq_display_value("readout_len_s", channel_config.readout_len_s)),
                "readout_start_s": tk.StringVar(value=self._format_ezq_display_value("readout_start_s", channel_config.readout_start_s)),
                "readout_phase_rad": tk.StringVar(value=self._format_ezq_display_value("readout_phase_rad", channel_config.readout_phase_rad)),
                "readout_edge_s": tk.StringVar(value=self._format_ezq_display_value("readout_edge_s", channel_config.readout_edge_s)),
                "readout_flattop_s": tk.StringVar(value=self._format_ezq_display_value("readout_flattop_s", channel_config.readout_flattop_s)),
                "readout_zpa": tk.StringVar(value=self._format_ezq_display_value("readout_zpa", channel_config.readout_zpa)),
                "timing_lag_xy_s": tk.StringVar(value=self._format_ezq_display_value("timing_lag_xy_s", channel_config.timing_lag_xy_s)),
                "period_s": tk.StringVar(value=self._format_ezq_display_value("period_s", channel_config.period_s)),
            }
        return variables

    def _format_ezq_display_value(self, key: str, value: float | int | str) -> str:
        unit = EZQ_FIELD_UNITS.get(key)
        if unit == "text":
            return str(value)
        if unit == "mhz":
            return to_display_mhz(float(value))
        if unit == "ns":
            return to_display_ns(float(value))
        return _format_display_value(float(value))

    def _apply_channel_settings(self, config: model.WaveformConfig) -> None:
        channel_configs = {channel: getattr(config, channel) for channel in CHANNELS}
        for channel, channel_config in channel_configs.items():
            if channel_config is None:
                continue
            fields = self.channel_fields[channel]
            self.channel_enabled[channel].set(channel_config.waveform_type.lower() != "off")
            self.channel_type[channel].set(_gui_waveform_type(channel_config.waveform_type))
            fields["freq_hz"].set(to_display_mhz(channel_config.freq_hz))
            fields["phase_rad"].set(f"{channel_config.phase_rad:g}")
            fields["amplitude"].set(str(channel_config.amplitude))
            fields["duration_s"].set(to_display_ns(channel_config.duration_s))

    def _configure_style(self) -> None:
        self.root.title("RFSoC Waveform Sender")
        self.root.geometry("1180x760")
        self.root.minsize(WINDOW_MIN_WIDTH_PX, WINDOW_MIN_HEIGHT_PX)
        self.root.configure(background=COLOR_BACKGROUND)
        style = ttk.Style(self.root)
        style.theme_use("clam")
        style.configure("TFrame", background=COLOR_BACKGROUND)
        style.configure("Card.TFrame", background=COLOR_CARD, relief="flat")
        style.configure("TLabel", background=COLOR_BACKGROUND, foreground=COLOR_TEXT, font=("TkDefaultFont", 10))
        style.configure("Card.TLabel", background=COLOR_CARD, foreground=COLOR_TEXT, font=("TkDefaultFont", 10))
        style.configure("Title.TLabel", background=COLOR_BACKGROUND, foreground=COLOR_TEXT_STRONG, font=("TkDefaultFont", 20, "bold"))
        style.configure("Hint.TLabel", background=COLOR_BACKGROUND, foreground=COLOR_TEXT_MUTED, font=("TkDefaultFont", 10))
        style.configure("Section.TLabel", background=COLOR_CARD, foreground=COLOR_TEXT_STRONG, font=("TkDefaultFont", 11, "bold"))
        style.configure("PanelTitle.TLabel", background=COLOR_CARD, foreground=COLOR_TEXT_STRONG, font=("TkDefaultFont", 13, "bold"))
        style.configure("Accent.TButton", background=COLOR_ACCENT, foreground=COLOR_ACCENT_TEXT, font=("TkDefaultFont", 10, "bold"))
        style.map("Accent.TButton", background=[("active", COLOR_ACCENT_ACTIVE)])
        style.configure("TButton", padding=(10, 6))
        style.configure("TEntry", fieldbackground=COLOR_INPUT_BACKGROUND, foreground=COLOR_INPUT_TEXT)
        style.configure("TCombobox", fieldbackground=COLOR_INPUT_BACKGROUND, foreground=COLOR_INPUT_TEXT)
        style.configure("TNotebook", background=COLOR_CARD, borderwidth=0, tabmargins=(0, 0, 0, 8))
        style.configure("TNotebook.Tab", background=COLOR_BACKGROUND, foreground=COLOR_TEXT, padding=(12, 8))
        style.map(
            "TNotebook.Tab",
            background=[("selected", COLOR_ACCENT), ("active", COLOR_CARD)],
            foreground=[("selected", COLOR_ACCENT_TEXT), ("active", COLOR_TEXT_STRONG)],
        )
        style.configure("TCheckbutton", background=COLOR_CARD, foreground=COLOR_TEXT)
        style.map(
            "TCheckbutton",
            background=[("active", COLOR_CARD), ("selected", COLOR_CARD), ("!disabled", COLOR_CARD)],
            foreground=[("active", COLOR_TEXT), ("selected", COLOR_TEXT), ("!disabled", COLOR_TEXT), ("disabled", COLOR_DISABLED_TEXT)],
            indicatorcolor=[("selected", COLOR_ACCENT), ("!selected", COLOR_BACKGROUND)],
        )

    def _build_widgets(self) -> None:
        self.grid(row=0, column=0, sticky="nsew")
        self.root.rowconfigure(0, weight=1)
        self.root.columnconfigure(0, weight=1)
        self.columnconfigure(0, weight=1)
        self.rowconfigure(1, weight=1)

        ttk.Label(self, text="RFSoC Waveform Console", style="Title.TLabel").grid(row=0, column=0, sticky="w")
        ttk.Label(
            self,
            text=(
                f"CH1-CH8 RFDC IQ playback, interleaved_512b DDR layout, "
                f"{host.DAC_XY_FS / 1e6:g} MS/s complex IQ input, {host.DAC_AXIS_HZ / 1e6:g} MHz AXIS."
            ),
            style="Hint.TLabel",
        ).grid(row=0, column=0, sticky="e", padx=(20, 0))

        workspace = ttk.Panedwindow(self, orient="horizontal")
        workspace.grid(row=1, column=0, sticky="nsew", pady=(16, 0))

        controls_shell = ttk.Frame(workspace, style="Card.TFrame")
        controls_shell.rowconfigure(0, weight=1)
        controls_shell.columnconfigure(0, weight=1)
        workspace.add(controls_shell, weight=0)

        self.control_book = view.ScrollableNotebook(
            controls_shell,
            CONTROL_TABS,
            CONTROL_PANEL_WIDTH_PX,
            COLOR_CARD,
            CONTROL_SCROLLBAR_MARKERS,
        )
        self.control_notebook = self.control_book.notebook
        self.control_tab_canvases = self.control_book.canvases
        self._build_setup_tab(self.control_book[CONTROL_TABS[0]])
        self._build_quantum_panel(self.control_book[CONTROL_TABS[1]])
        self._build_channels_tab(self.control_book[CONTROL_TABS[2]])
        self._build_ila_tab(self.control_book[CONTROL_TABS[3]])

        self.preview_panel = view.PreviewWorkbench(
            workspace,
            COLOR_CARD,
            PREVIEW_COLORS,
            host.DAC_XY_FS,
        )
        workspace.add(self.preview_panel, weight=1)

        self.run_console = view.RunConsole(
            workspace,
            (
                (ACTION_BUTTONS[0], self.preview_waveforms, "Accent.TButton"),
                (ACTION_BUTTONS[1], self.test_connection, "TButton"),
                (ACTION_BUTTONS[2], self.save_or_dry_run, "TButton"),
                (ACTION_BUTTONS[3], self.send_to_board, "TButton"),
                (EXTREME_TEST_BUTTON_TEXT, self.run_extreme_test, "TButton"),
                (ILA_CAPTURE_BUTTON_TEXT, self.run_ila_capture_report, "TButton"),
            ),
            COLOR_LOG_BACKGROUND,
            COLOR_TEXT,
        )
        workspace.add(self.run_console, weight=0)

        if self.dry_run.get():
            self._append_log("Ready. Dry run is enabled.")
        else:
            self._append_log("Ready. Send to board is enabled.")
        self._append_log(f"Settings file: {self.settings_path}")
        if self._settings_loaded:
            self._append_log("Loaded saved GUI settings.")

    def _build_setup_tab(self, parent: ttk.Frame) -> None:
        form = view.ParameterForm(parent)
        form.section("Target Connection", 0)
        form.entry("Board IP", self.ip, 1)
        form.entry("UDP port", self.port, 2)
        form.entry("UDP interface", self.udp_interface, 3)
        form.entry("Source IP", self.udp_source_ip, 4)
        form.entry("Timeout (s)", self.timeout_s, 5)
        form.entry("Post-upload sleep (s)", self.post_upload_sleep_s, 6)

        form.section("Waveform Source", 7)
        form.combobox("Source", self.waveform_source, WAVEFORM_SOURCE_MODES, 8, self._disable_combobox_mousewheel)

        form.section("Global Playback", 9)
        form.entry(GLOBAL_SAMPLE_RATE_LABEL, self.sample_rate_hz, 10)
        form.entry(GLOBAL_RFDC_INTERPOLATION_LABEL, self.rfdc_interpolation, 11)
        form.entry(GLOBAL_AXIS_FREQ_LABEL, self.axis_freq_hz, 12)
        form.checkbutton("Wait for trigger", self.wait_for_trigger, 13)
        form.checkbutton("Loop playback", self.loop, 14)
        form.checkbutton("Dry run, do not send UDP", self.dry_run, 15)

        form.section("Extreme Playback Test", 16)
        form.entry("Bytes / channel", self.extreme_bytes_per_channel, 17)
        form.combobox(
            "Pattern",
            self.extreme_pattern,
            (host.MAX_LENGTH_PATTERN_LOWFREQ_SINE, host.MAX_LENGTH_PATTERN_CW_MARKER),
            18,
            self._disable_combobox_mousewheel,
        )
        form.entry("Sine freq (Hz)", self.extreme_sine_freq_hz, 19)
        form.entry("Sine amplitude", self.extreme_sine_amplitude, 20)
        form.entry("Beats / UDP datagram", self.extreme_beats_per_datagram, 21)
        form.entry("Marker bytes / channel", self.extreme_marker_bytes_per_channel, 22)
        form.checkbutton("Use waveform cache", self.extreme_use_waveform_cache, 23)
        form.checkbutton("Regenerate cache", self.extreme_force_waveform_cache, 24)

        form.section("Artifacts", 25)
        form.entry("Output dir", self.output_dir, 26)
        form.browse_row(self._browse_output_dir, 25)

    def _build_channels_tab(self, parent: ttk.Frame) -> None:
        self.channel_frames = {}
        for index, channel in enumerate(CHANNELS):
            self._build_channel_panel(parent, channel, CHANNEL_PANEL_TITLES[channel], index * 2)

    def _build_ila_tab(self, parent: ttk.Frame) -> None:
        form = view.ParameterForm(parent)
        form.section("ILA Capture / Report", 0)
        form.entry("Bitstream path", self.ila_bitstream_path, 1)
        form.browse_row(self._browse_ila_bitstream, 2)
        form.entry("LTX path", self.ila_ltx_path, 3)
        form.browse_row(self._browse_ila_ltx, 4)
        form.entry("Report dir", self.ila_report_dir, 5)
        form.browse_row(self._browse_ila_report_dir, 6)
        form.combobox("Program mode", self.ila_program_mode, ILA_PROGRAM_MODES, 7, self._disable_combobox_mousewheel)

    def _build_channel_panel(self, parent: ttk.Frame, channel: str, title: str, row: int) -> None:
        view.ParameterForm(parent).section(title, row)
        frame = ttk.Frame(parent, style="Card.TFrame")
        frame.grid(row=row + 1, column=0, columnspan=2, sticky="ew", pady=(0, 4))
        frame.columnconfigure(1, weight=1)
        self.channel_frames[channel] = frame
        ttk.Checkbutton(
            frame,
            text="Enable",
            variable=self.channel_enabled[channel],
            command=lambda channel=channel: self._set_channel_fields(channel),
        ).grid(row=0, column=0, columnspan=2, sticky="w", pady=(0, 4))
        ttk.Label(frame, text="Waveform", style="Card.TLabel").grid(row=1, column=0, sticky="w", pady=4, padx=(0, 10))
        menu = ttk.Combobox(frame, textvariable=self.channel_type[channel], values=WAVEFORM_TYPES, state="readonly", width=18)
        menu.grid(row=1, column=1, sticky="ew", pady=4)
        self._disable_combobox_mousewheel(menu)
        menu.bind("<<ComboboxSelected>>", lambda _event, channel=channel: self._set_channel_fields(channel))

    def _build_quantum_panel(self, parent: ttk.Frame) -> None:
        form = view.ParameterForm(parent)
        row = 0
        for section in EZQ_PARAMETER_SECTIONS:
            row = form.section_fields(section, self.ezq_fields, row)

        ttk.Button(parent, text="Apply Global To All Channels", command=self._copy_global_ezq_to_channels).grid(
            row=row, column=0, columnspan=2, sticky="ew", pady=(10, 4)
        )
        row += 1

        form.section("Per-channel Quantum Pulses", row)
        row += 1
        self.ezq_channel_dynamic_frames = {}
        for index, channel in enumerate(CHANNELS):
            row = self._build_ezq_channel_panel(parent, channel, index + 1, row)

    def _build_ezq_channel_panel(self, parent: ttk.Frame, channel: str, channel_number: int, row: int) -> int:
        frame = ttk.Frame(parent, style="Card.TFrame")
        frame.grid(row=row, column=0, columnspan=2, sticky="ew", pady=(0, 10))
        frame.columnconfigure(1, weight=1)
        role = host.CHANNEL_ROLES.get(channel_number, "xy")
        self.ezq_channel_waveform[channel].set(role)
        ttk.Label(frame, text=f"CH{channel_number} / {role.upper()}", style="Section.TLabel").grid(row=0, column=0, sticky="w", pady=(0, 4))
        ttk.Checkbutton(frame, text="Enable", variable=self.ezq_channel_enabled[channel]).grid(row=0, column=1, sticky="e", pady=(0, 4))
        ttk.Label(frame, text="Role", style="Card.TLabel", wraplength=180).grid(row=1, column=0, sticky="w", pady=3, padx=(0, 10))
        menu = ttk.Combobox(
            frame,
            textvariable=self.ezq_channel_waveform[channel],
            values=EZQ_CHANNEL_WAVEFORMS,
            state="disabled",
            width=20,
        )
        menu.grid(row=1, column=1, sticky="ew", pady=3)
        self._disable_combobox_mousewheel(menu)
        menu.bind("<<ComboboxSelected>>", lambda _event, channel=channel: self._set_ezq_channel_fields(channel))
        dynamic = ttk.Frame(frame, style="Card.TFrame")
        dynamic.grid(row=2, column=0, columnspan=2, sticky="ew")
        dynamic.columnconfigure(1, weight=1)
        self.ezq_channel_dynamic_frames[channel] = dynamic
        self._set_ezq_channel_fields(channel)
        return row + 1

    def _set_ezq_channel_fields(self, channel: str) -> None:
        frame = self.ezq_channel_dynamic_frames[channel]
        for child in frame.grid_slaves():
            child.destroy()
        waveform = self.ezq_channel_waveform[channel].get().lower()
        if waveform == "xy":
            fields = _ezq_xy_gate_fields(self.ezq_channel_fields[channel]["xy_gate"].get())
        elif waveform == "z":
            fields = _ezq_z_shape_fields(self.ezq_channel_fields[channel]["z_shape"].get())
        else:
            fields = EZQ_CHANNEL_FIELD_GROUPS.get(waveform, EZQ_CHANNEL_FIELD_GROUPS["xy"])
        for field_row, field in enumerate(fields):
            view.grid_field_label(frame, field.label, field_row, wraplength=180)
            if field.key == "xy_gate":
                menu = ttk.Combobox(
                    frame,
                    textvariable=self.ezq_channel_fields[channel][field.key],
                    values=EZQ_XY_GATES,
                    state="readonly",
                    width=20,
                )
                menu.grid(row=field_row, column=1, sticky="ew", pady=3)
                self._disable_combobox_mousewheel(menu)
                menu.bind("<<ComboboxSelected>>", lambda _event, channel=channel: self._set_ezq_channel_fields(channel))
            elif field.key == "z_shape":
                menu = ttk.Combobox(
                    frame,
                    textvariable=self.ezq_channel_fields[channel][field.key],
                    values=EZQ_Z_SHAPES,
                    state="readonly",
                    width=20,
                )
                menu.grid(row=field_row, column=1, sticky="ew", pady=3)
                self._disable_combobox_mousewheel(menu)
                menu.bind("<<ComboboxSelected>>", lambda _event, channel=channel: self._set_ezq_channel_fields(channel))
            else:
                entry = ttk.Entry(frame, textvariable=self.ezq_channel_fields[channel][field.key], width=20)
                entry.grid(row=field_row, column=1, sticky="ew", pady=3)

    def _copy_global_ezq_to_channels(self) -> None:
        mapping = {
            "f10_hz": "f10_hz",
            "f21_hz": "f21_hz",
            "fc_hz": "fc_hz",
            "nonlinearity_hz": "nonlinearity_hz",
            "pi_amp": "pi_amp",
            "pi_len_s": "pi_len_s",
            "pi_fwhm_s": "pi_fwhm_s",
            "pi_alpha": "pi_alpha",
            "pi_amp_half": "pi_amp_half",
            "pi_len_half_s": "pi_len_half_s",
            "pi_fwhm_half_s": "pi_fwhm_half_s",
            "pi_alpha_half": "pi_alpha_half",
            "pi_amp21": "pi_amp21",
            "pi_amp21_half": "pi_amp21_half",
            "pi_df_hz": "pi_df_hz",
            "xy_phase_rad": "xy_phase_rad",
            "spec_amp": "spec_amp",
            "spec_len_s": "spec_len_s",
            "z_amp": "pi_amp_z",
            "z_len_s": "pi_len_z_s",
            "z_shape": "z_shape",
            "z_start_s": "z_start_s",
            "z_gate_time_s": "z_gate_time_s",
            "z_edge_s": "z_edge_s",
            "z_ripple0": "z_ripple0",
            "z_ripple1": "z_ripple1",
            "z_ripple2": "z_ripple2",
            "z_ripple3": "z_ripple3",
            "readout_freq_hz": "readout_freq_hz",
            "readout_fc_hz": "readout_fc_hz",
            "readout_len_s": "readout_len_s",
            "readout_start_s": "readout_start_s",
            "readout_edge_s": "readout_edge_s",
            "readout_flattop_s": "readout_flattop_s",
            "readout_zpa": "readout_zpa",
            "timing_lag_xy_s": "timing_lag_xy_s",
            "period_s": "period_s",
        }
        for fields in self.ezq_channel_fields.values():
            for channel_key, global_key in mapping.items():
                fields[channel_key].set(self.ezq_fields[global_key].get())
        if self._preview_binder is not None:
            self._preview_binder.schedule()

    def _disable_combobox_mousewheel(self, combobox: ttk.Combobox) -> None:
        for event_name in COMBOBOX_WHEEL_BLOCK_EVENTS:
            combobox.bind(event_name, _block_combobox_mousewheel)

    def _set_channel_fields(self, channel: str) -> None:
        frame = self.channel_frames[channel]
        for child in frame.grid_slaves():
            info = child.grid_info()
            if int(info.get("row", 0)) > 1:
                child.destroy()
        if not self.channel_enabled[channel].get():
            ttk.Label(frame, text="Disabled; this channel outputs zero samples.", style="Card.TLabel").grid(
                row=2, column=0, columnspan=2, sticky="w", pady=4
            )
            if self._preview_binder is not None:
                self._preview_binder.schedule()
            return
        waveform_type = _gui_waveform_type(self.channel_type[channel].get())
        if waveform_type != self.channel_type[channel].get():
            self.channel_type[channel].set(waveform_type)
        fields = CHANNEL_FIELD_GROUPS[waveform_type]
        if not fields:
            ttk.Label(frame, text="Outputs zero samples.", style="Card.TLabel").grid(row=1, column=0, columnspan=2, sticky="w", pady=4)
        for row_offset, field_name in enumerate(fields, start=2):
            ttk.Label(frame, text=_field_display_label(field_name), style="Card.TLabel", wraplength=180).grid(
                row=row_offset, column=0, sticky="w", pady=4, padx=(0, 10)
            )
            variable = self.channel_fields[channel][field_name]
            ttk.Entry(frame, textvariable=variable, width=22).grid(row=row_offset, column=1, sticky="ew", pady=4)
        if self._preview_binder is not None:
            self._preview_binder.schedule()

    def _browse_output_dir(self) -> None:
        selected = filedialog.askdirectory(initialdir=self.output_dir.get() or str(Path.home()))
        if selected:
            self.output_dir.set(selected)

    def _browse_ila_bitstream(self) -> None:
        selected = filedialog.askopenfilename(initialfile=Path(self.ila_bitstream_path.get()).name, filetypes=(("Bitstreams", "*.bit"), ("All files", "*")))
        if selected:
            self.ila_bitstream_path.set(selected)

    def _browse_ila_ltx(self) -> None:
        selected = filedialog.askopenfilename(initialfile=Path(self.ila_ltx_path.get()).name, filetypes=(("LTX probes", "*.ltx"), ("All files", "*")))
        if selected:
            self.ila_ltx_path.set(selected)

    def _browse_ila_report_dir(self) -> None:
        selected = filedialog.askdirectory(initialdir=self.ila_report_dir.get() or str(Path.home()))
        if selected:
            self.ila_report_dir.set(selected)

    def _parse_int(self, value: str) -> int:
        return int(value.strip(), 0)

    def _preview_variables(self) -> list[Any]:
        variables: list[Any] = [self.sample_rate_hz, self.axis_freq_hz, self.loop, self.wait_for_trigger, self.dry_run, self.waveform_source]
        variables.extend(self.ezq_fields.values())
        variables.extend(self.ezq_channel_enabled.values())
        variables.extend(self.ezq_channel_waveform.values())
        for channel_fields in self.ezq_channel_fields.values():
            variables.extend(channel_fields.values())
        variables.extend(self.channel_enabled.values())
        variables.extend(self.channel_type.values())
        for channel_fields in self.channel_fields.values():
            variables.extend(channel_fields.values())
        return variables

    def _settings_variables(self) -> list[Any]:
        variables = self._preview_variables()
        variables.extend(
            [
                self.output_dir,
                self.ip,
                self.port,
                self.udp_interface,
                self.udp_source_ip,
                self.timeout_s,
                self.post_upload_sleep_s,
                self.ila_bitstream_path,
                self.ila_ltx_path,
                self.ila_report_dir,
                self.ila_program_mode,
            ]
        )
        return variables

    def _collect_channel_config(self, channel: str) -> model.ChannelWaveformConfig:
        fields = self.channel_fields[channel]
        if not self.channel_enabled[channel].get():
            return model.ChannelWaveformConfig(
                waveform_type="off",
                freq_hz=from_display_mhz(fields["freq_hz"].get()),
                phase_rad=float(fields["phase_rad"].get()),
                amplitude=self._parse_int(fields["amplitude"].get()),
                duration_s=from_display_ns(fields["duration_s"].get()),
            )
        return model.ChannelWaveformConfig(
            waveform_type=self.channel_type[channel].get(),
            freq_hz=from_display_mhz(fields["freq_hz"].get()),
            phase_rad=float(fields["phase_rad"].get()),
            amplitude=self._parse_int(fields["amplitude"].get()),
            duration_s=from_display_ns(fields["duration_s"].get()),
        )

    def _parse_ezq_value(self, key: str) -> float:
        value = self.ezq_fields[key].get()
        unit = EZQ_FIELD_UNITS.get(key)
        if unit == "mhz":
            return from_display_mhz(value)
        if unit == "ns":
            return from_display_ns(value)
        return float(value)

    def _parse_ezq_channel_value(self, channel: str, key: str) -> float:
        value = self.ezq_channel_fields[channel][key].get()
        unit = EZQ_FIELD_UNITS.get(key)
        if unit == "mhz":
            return from_display_mhz(value)
        if unit == "ns":
            return from_display_ns(value)
        return float(value)

    def _collect_ezq_channel_config(self, channel: str) -> model.EzqChannelConfig:
        return model.EzqChannelConfig(
            enabled=bool(self.ezq_channel_enabled[channel].get()),
            waveform=self.ezq_channel_waveform[channel].get(),
            xy_gate=self.ezq_channel_fields[channel]["xy_gate"].get(),
            target_rf_hz=self._parse_ezq_channel_value(channel, "target_rf_hz"),
            detune_hz=self._parse_ezq_channel_value(channel, "detune_hz"),
            start_time_s=self._parse_ezq_channel_value(channel, "start_time_s"),
            f10_hz=self._parse_ezq_channel_value(channel, "f10_hz"),
            f21_hz=self._parse_ezq_channel_value(channel, "f21_hz"),
            fc_hz=self._parse_ezq_channel_value(channel, "fc_hz"),
            nonlinearity_hz=self._parse_ezq_channel_value(channel, "nonlinearity_hz"),
            pi_amp=self._parse_ezq_channel_value(channel, "pi_amp"),
            pi_len_s=self._parse_ezq_channel_value(channel, "pi_len_s"),
            pi_fwhm_s=self._parse_ezq_channel_value(channel, "pi_fwhm_s"),
            pi_alpha=self._parse_ezq_channel_value(channel, "pi_alpha"),
            pi_amp_half=self._parse_ezq_channel_value(channel, "pi_amp_half"),
            pi_len_half_s=self._parse_ezq_channel_value(channel, "pi_len_half_s"),
            pi_fwhm_half_s=self._parse_ezq_channel_value(channel, "pi_fwhm_half_s"),
            pi_alpha_half=self._parse_ezq_channel_value(channel, "pi_alpha_half"),
            pi_amp21=self._parse_ezq_channel_value(channel, "pi_amp21"),
            pi_amp21_half=self._parse_ezq_channel_value(channel, "pi_amp21_half"),
            pi_df_hz=self._parse_ezq_channel_value(channel, "pi_df_hz"),
            xy_phase_rad=self._parse_ezq_channel_value(channel, "xy_phase_rad"),
            spec_amp=self._parse_ezq_channel_value(channel, "spec_amp"),
            spec_len_s=self._parse_ezq_channel_value(channel, "spec_len_s"),
            z_amp=self._parse_ezq_channel_value(channel, "z_amp"),
            z_len_s=self._parse_ezq_channel_value(channel, "z_len_s"),
            z_shape=self.ezq_channel_fields[channel]["z_shape"].get(),
            z_start_s=self._parse_ezq_channel_value(channel, "z_start_s"),
            z_gate_time_s=self._parse_ezq_channel_value(channel, "z_gate_time_s"),
            z_edge_s=self._parse_ezq_channel_value(channel, "z_edge_s"),
            z_ripple0=self._parse_ezq_channel_value(channel, "z_ripple0"),
            z_ripple1=self._parse_ezq_channel_value(channel, "z_ripple1"),
            z_ripple2=self._parse_ezq_channel_value(channel, "z_ripple2"),
            z_ripple3=self._parse_ezq_channel_value(channel, "z_ripple3"),
            readout_freq_hz=self._parse_ezq_channel_value(channel, "readout_freq_hz"),
            readout_fc_hz=self._parse_ezq_channel_value(channel, "readout_fc_hz"),
            readout_amp=self._parse_ezq_channel_value(channel, "readout_amp"),
            readout_len_s=self._parse_ezq_channel_value(channel, "readout_len_s"),
            readout_start_s=self._parse_ezq_channel_value(channel, "readout_start_s"),
            readout_phase_rad=self._parse_ezq_channel_value(channel, "readout_phase_rad"),
            readout_edge_s=self._parse_ezq_channel_value(channel, "readout_edge_s"),
            readout_flattop_s=self._parse_ezq_channel_value(channel, "readout_flattop_s"),
            readout_zpa=self._parse_ezq_channel_value(channel, "readout_zpa"),
            timing_lag_xy_s=self._parse_ezq_channel_value(channel, "timing_lag_xy_s"),
            period_s=self._parse_ezq_channel_value(channel, "period_s"),
        )

    def _collect_ezq_config(self) -> model.EzqPulseConfig:
        channel_mask = 0
        for index, channel in enumerate(CHANNELS):
            if self.ezq_channel_enabled[channel].get():
                channel_mask |= 1 << index
        return model.EzqPulseConfig(
            f10_hz=self._parse_ezq_value("f10_hz"),
            f21_hz=self._parse_ezq_value("f21_hz"),
            fc_hz=self._parse_ezq_value("fc_hz"),
            uwave_power_dbm=self._parse_ezq_value("uwave_power_dbm"),
            uwave_phase_rad=self._parse_ezq_value("uwave_phase_rad"),
            nonlinearity_hz=self._parse_ezq_value("nonlinearity_hz"),
            pi_amp=self._parse_ezq_value("pi_amp"),
            pi_len_s=self._parse_ezq_value("pi_len_s"),
            pi_fwhm_s=self._parse_ezq_value("pi_fwhm_s"),
            pi_alpha=self._parse_ezq_value("pi_alpha"),
            pi_amp_half=self._parse_ezq_value("pi_amp_half"),
            pi_len_half_s=self._parse_ezq_value("pi_len_half_s"),
            pi_fwhm_half_s=self._parse_ezq_value("pi_fwhm_half_s"),
            pi_alpha_half=self._parse_ezq_value("pi_alpha_half"),
            pi_amp21=self._parse_ezq_value("pi_amp21"),
            pi_amp21_half=self._parse_ezq_value("pi_amp21_half"),
            pi_df_hz=self._parse_ezq_value("pi_df_hz"),
            xy_phase_rad=self._parse_ezq_value("xy_phase_rad"),
            spec_amp=self._parse_ezq_value("spec_amp"),
            spec_len_s=self._parse_ezq_value("spec_len_s"),
            z_offset=self._parse_ezq_value("z_offset"),
            pi_amp_z=self._parse_ezq_value("pi_amp_z"),
            pi_len_z_s=self._parse_ezq_value("pi_len_z_s"),
            z_shape=self.ezq_fields["z_shape"].get(),
            z_start_s=self._parse_ezq_value("z_start_s"),
            z_gate_time_s=self._parse_ezq_value("z_gate_time_s"),
            z_edge_s=self._parse_ezq_value("z_edge_s"),
            z_ripple0=self._parse_ezq_value("z_ripple0"),
            z_ripple1=self._parse_ezq_value("z_ripple1"),
            z_ripple2=self._parse_ezq_value("z_ripple2"),
            z_ripple3=self._parse_ezq_value("z_ripple3"),
            readout_freq_hz=self._parse_ezq_value("readout_freq_hz"),
            readout_fc_hz=self._parse_ezq_value("readout_fc_hz"),
            readout_len_s=self._parse_ezq_value("readout_len_s"),
            readout_edge_s=self._parse_ezq_value("readout_edge_s"),
            readout_flattop_s=self._parse_ezq_value("readout_flattop_s"),
            readout_zpa=self._parse_ezq_value("readout_zpa"),
            readout_power_dbm=self._parse_ezq_value("readout_power_dbm"),
            ring_power_dbm=self._parse_ezq_value("ring_power_dbm"),
            readout_uwave_power_dbm=self._parse_ezq_value("readout_uwave_power_dbm"),
            ring_len_s=self._parse_ezq_value("ring_len_s"),
            readout_start_s=self._parse_ezq_value("readout_start_s"),
            adc_start_delay_s=self._parse_ezq_value("adc_start_delay_s"),
            timing_lag_xy_s=self._parse_ezq_value("timing_lag_xy_s"),
            timing_lag_z_s=self._parse_ezq_value("timing_lag_z_s"),
            timing_lag_read_s=self._parse_ezq_value("timing_lag_read_s"),
            repeat=self._parse_int(self.ezq_fields["repeat"].get()),
            period_s=self._parse_ezq_value("period_s"),
            record_duration_s=self._parse_ezq_value("record_duration_s"),
            channel_mask=channel_mask,
            ch1=self._collect_ezq_channel_config("ch1"),
            ch2=self._collect_ezq_channel_config("ch2"),
            ch3=self._collect_ezq_channel_config("ch3"),
            ch4=self._collect_ezq_channel_config("ch4"),
            ch5=self._collect_ezq_channel_config("ch5"),
            ch6=self._collect_ezq_channel_config("ch6"),
            ch7=self._collect_ezq_channel_config("ch7"),
            ch8=self._collect_ezq_channel_config("ch8"),
        )

    def _collect_config(self, dry_run: bool | None = None) -> model.WaveformConfig:
        ezq = self._collect_ezq_config()
        common = {
            "output_dir": Path(self.output_dir.get()).expanduser(),
            "sample_rate_hz": from_display_gsps(self.sample_rate_hz.get()),
            "rfdc_interpolation": self._parse_int(self.rfdc_interpolation.get()),
            "axis_freq_hz": from_display_mhz(self.axis_freq_hz.get()),
            "loop": bool(self.loop.get()),
            "wait_for_trigger": bool(self.wait_for_trigger.get()),
            "dry_run": bool(self.dry_run.get() if dry_run is None else dry_run),
            "ezq": ezq,
        }
        if self.waveform_source.get() == "ezq-quantum":
            return model.WaveformConfig(mode="ezq-quantum", **common)
        return model.WaveformConfig(
            mode="per-channel",
            **common,
            ch1=self._collect_channel_config("ch1"),
            ch2=self._collect_channel_config("ch2"),
            ch3=self._collect_channel_config("ch3"),
            ch4=self._collect_channel_config("ch4"),
            ch5=self._collect_channel_config("ch5"),
            ch6=self._collect_channel_config("ch6"),
            ch7=self._collect_channel_config("ch7"),
            ch8=self._collect_channel_config("ch8"),
        )

    def _collect_connection(self) -> model.ConnectionConfig:
        return model.ConnectionConfig(
            ip=self.ip.get().strip(),
            port=self._parse_int(self.port.get()),
            udp_interface=self.udp_interface.get().strip(),
            udp_source_ip=self.udp_source_ip.get().strip(),
            timeout_s=float(self.timeout_s.get()),
            post_upload_sleep_s=float(self.post_upload_sleep_s.get()),
        )

    def _collect_ila_config(self) -> model.IlaReportConfig:
        return model.IlaReportConfig(
            bitstream_path=Path(self.ila_bitstream_path.get()).expanduser(),
            ltx_path=Path(self.ila_ltx_path.get()).expanduser(),
            output_dir=Path(self.ila_report_dir.get()).expanduser(),
            artifact_dir=Path(self.output_dir.get()).expanduser(),
            program_mode=self.ila_program_mode.get(),
        )

    def _collect_extreme_config(self) -> model.ExtremePlaybackConfig:
        return model.ExtremePlaybackConfig(
            output_dir=Path(self.output_dir.get()).expanduser(),
            bytes_per_channel=self.extreme_bytes_per_channel.get().strip(),
            pattern=self.extreme_pattern.get().strip(),
            sine_freq_hz=float(self.extreme_sine_freq_hz.get()),
            sine_amplitude=self._parse_int(self.extreme_sine_amplitude.get()),
            beats_per_datagram=self._parse_int(self.extreme_beats_per_datagram.get()),
            marker_bytes_per_channel=self._parse_int(self.extreme_marker_bytes_per_channel.get()),
            use_waveform_cache=bool(self.extreme_use_waveform_cache.get()),
            force_waveform_cache=bool(self.extreme_force_waveform_cache.get()),
            waveform_cache_dir=Path(self.output_dir.get()).expanduser() / "waveform_cache",
            wait_for_trigger=bool(self.wait_for_trigger.get()),
            dry_run=bool(self.dry_run.get()),
        )

    def _collect_settings(self) -> model.GuiSettings:
        return model.GuiSettings(
            waveform=self._collect_config(),
            connection=self._collect_connection(),
            ila=self._collect_ila_config(),
        )

    def _save_settings_from_live_edit(self) -> None:
        try:
            model.save_gui_settings(self._collect_settings(), self.settings_path)
        except Exception as exc:
            self._append_log(f"settings autosave skipped: {exc}")

    def preview_waveforms(self) -> None:
        try:
            generated = model.generate_waveforms(self._collect_config(dry_run=True))
            self._draw_preview(generated)
            for label, wave in generated.channel_items():
                self._append_log(model.summarize_waveform(f"Preview {label}", wave))
        except Exception as exc:
            messagebox.showerror("Preview failed", str(exc))
            self._append_log(f"preview failed: {exc}")

    def _preview_from_live_edit(self) -> None:
        try:
            generated = model.generate_waveforms(self._collect_config(dry_run=True))
            self._draw_preview(generated)
        except Exception as exc:
            self._append_log(f"live preview pending valid settings: {exc}")

    def _draw_preview(self, generated: model.GeneratedWaveforms) -> None:
        self.preview_panel.draw(generated)

    def save_or_dry_run(self) -> None:
        self._run_controller(dry_run=True)

    def test_connection(self) -> None:
        try:
            connection = self._collect_connection()
        except Exception as exc:
            messagebox.showerror("Invalid connection settings", str(exc))
            return
        self._append_log(f"connection test: sending probe to {connection.ip}:{connection.port}...")
        worker = threading.Thread(target=self._worker_test_connection, args=(connection,), daemon=True)
        worker.start()

    def _worker_test_connection(self, connection: model.ConnectionConfig) -> None:
        result = model.test_connection(connection)
        self.messages.put(("connection", result))

    def run_ila_capture_report(self) -> None:
        try:
            config = self._collect_ila_config()
            connection = self._collect_connection()
        except Exception as exc:
            messagebox.showerror("Invalid ILA settings", str(exc))
            return
        command = model.build_ila_capture_command(config, connection)
        self._append_log("ila capture: starting capture/report...")
        self._append_log(f"ila artifact dir: {config.artifact_dir}")
        self._append_log(f"ila report dir: {config.output_dir}")
        self._append_log(f"ila command: {shlex.join(command)}")
        worker = threading.Thread(target=self._worker_ila_capture_report, args=(config, connection), daemon=True)
        worker.start()

    def _worker_ila_capture_report(self, config: model.IlaReportConfig, connection: model.ConnectionConfig) -> None:
        try:
            result = model.run_ila_capture_report(config, connection)
            self.messages.put(("ila", result))
        except Exception as exc:
            self.messages.put(("error", exc))

    def run_extreme_test(self) -> None:
        try:
            extreme_config = self._collect_extreme_config()
            waveform_config = self._collect_config(dry_run=True)
            connection = self._collect_connection()
            summary = model.build_extreme_playback_summary(extreme_config, connection)
        except Exception as exc:
            messagebox.showerror("Invalid extreme test settings", str(exc))
            return
        if not messagebox.askyesno(
            "Confirm extreme playback test",
            f"This will stream a long max-length CW marker record to DDR.\n\n{summary}\n\nContinue?",
        ):
            return
        self._append_log("extreme: starting max-length playback test...")
        self._append_log(f"extreme summary:\n{summary}")
        worker = threading.Thread(
            target=self._worker_extreme_test,
            args=(extreme_config, waveform_config, connection),
            daemon=True,
        )
        worker.start()

    def _worker_extreme_test(
        self,
        extreme_config: model.ExtremePlaybackConfig,
        waveform_config: model.WaveformConfig,
        connection: model.ConnectionConfig,
    ) -> None:
        try:
            result = model.run_extreme_playback(extreme_config, connection, waveform_config=waveform_config)
            self.messages.put(("extreme", result))
        except Exception as exc:
            self.messages.put(("error", exc))

    def send_to_board(self) -> None:
        try:
            config = self._collect_config(dry_run=False)
            connection = self._collect_connection()
        except Exception as exc:
            messagebox.showerror("Invalid settings", str(exc))
            return
        summary = model.build_send_summary(config, connection)
        if not messagebox.askyesno(SEND_CONFIRMATION_TITLE, f"This will send UDP packets to the configured RFSoC target.\n\n{summary}\n\nContinue?"):
            return
        self._run_controller(dry_run=False, config=config, connection=connection)

    def _run_controller(
        self,
        dry_run: bool,
        config: model.WaveformConfig | None = None,
        connection: model.ConnectionConfig | None = None,
    ) -> None:
        try:
            config = config or self._collect_config(dry_run=dry_run)
            connection = connection or self._collect_connection()
        except Exception as exc:
            messagebox.showerror("Invalid settings", str(exc))
            return
        self._append_log("progress: starting dry run..." if dry_run else "progress: starting send to board...")
        worker = threading.Thread(target=self._worker_run, args=(config, connection), daemon=True)
        worker.start()

    def _worker_run(self, config: model.WaveformConfig, connection: model.ConnectionConfig) -> None:
        try:
            result = self.controller.run(config, connection)
            self.messages.put(("result", result))
        except Exception as exc:
            self.messages.put(("error", exc))

    def _drain_messages(self) -> None:
        while True:
            try:
                kind, payload = self.messages.get_nowait()
            except queue.Empty:
                break
            if kind == "result":
                result = cast(model.ControllerResult, payload)
                self._draw_preview(result.generated)
                for line in result.log_lines:
                    self._append_log(line)
            elif kind == "connection":
                result = cast(model.ConnectionTestResult, payload)
                self._append_log(result.message)
                if not result.ok:
                    messagebox.showerror("Connection test failed", result.message)
            elif kind == "ila":
                result = cast(model.IlaReportResult, payload)
                for line in result.log_lines:
                    self._append_log(line)
                if not result.ok:
                    messagebox.showerror("ILA capture/report failed", f"Exit {result.returncode}; status {result.overall_status}")
            elif kind == "extreme":
                result = cast(model.ExtremePlaybackResult, payload)
                for line in result.log_lines:
                    self._append_log(line)
                self._append_log(
                    f"extreme complete: expected_duration={result.expected_duration_s:.9f}s, "
                    f"beats/channel={result.expected_rfdc_beats_per_channel}, "
                    f"bytes/channel={result.bytes_per_channel}"
                )
            else:
                self._append_log(f"operation failed: {payload}")
                messagebox.showerror("Operation failed", str(payload))
        self.after(100, self._drain_messages)

    def _append_log(self, text: str) -> None:
        self.run_console.append(text)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Launch the local RFSoC waveform sender GUI.")
    parser.add_argument("--smoke", action="store_true", help="import GUI dependencies and exit without opening a window")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.smoke:
        print(f"waveform_gui smoke ok: default_board={host.DEFAULT_BOARD_IP}:{host.DEFAULT_BOARD_PORT}")
        return 0
    try:
        root = tk.Tk()
    except tk.TclError as exc:
        print(
            "No graphical display is available. Run this from a desktop session, "
            "forward X11, or set DISPLAY before launching software/waveform_gui.py.",
            file=sys.stderr,
        )
        print(f"tkinter error: {exc}", file=sys.stderr)
        return 2
    WaveformSenderApp(root)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
