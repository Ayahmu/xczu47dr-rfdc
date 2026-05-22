#!/usr/bin/env python3
"""Tkinter entrypoint for the RFSoC X/Y waveform sender."""

from __future__ import annotations

import argparse
import queue
import sys
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, scrolledtext, ttk
from typing import Any, cast

from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg
from matplotlib.figure import Figure

import host
import waveform_gui_model as model


PREVIEW_TITLES = ("CH1 I-drive waveform (DDR X)", "CH2 Q-drive waveform (DDR Y)")


WAVEFORM_TYPES = ("quantum", "sine")
ACTION_BUTTONS = ("Preview", "Test Connection", "Save / Dry Run", "Send to Board")
ACTION_BUTTON_GRID_COLUMNS = 2
ACTION_BUTTON_GRID_STICKY = "ew"
ACTION_BUTTON_MIN_WIDTH_PX = 180
CONTROL_PANEL_WIDTH_PX = 420
WINDOW_MIN_WIDTH_PX = 1020
WINDOW_MIN_HEIGHT_PX = 680
SEND_CONFIRMATION_TITLE = "Confirm send to board"
GLOBAL_SAMPLE_RATE_LABEL = "Sample rate (GS/s)"

CHANNEL_FIELD_GROUPS = {
    "quantum": ("quantum_gate", "rotation_angle_rad", "freq_hz", "phase_rad", "delay_s", "duration_s", "amplitude"),
    "sine": ("freq_hz", "phase_rad", "amplitude", "encoding"),
}

CONTROL_SCROLLBAR_MARKERS = ("tk.Canvas", "ttk.Scrollbar", "yscrollcommand", "<MouseWheel>")
COMBOBOX_WHEEL_BLOCK_EVENTS = ("<MouseWheel>", "<Button-4>", "<Button-5>")

LABELS = {
    "pulse_preset": "Pulse preset",
    "quantum_gate": "Quantum gate (X=I, Y=Q+90deg, Z=paired phase)",
    "rotation_angle_rad": "Rotation angle (rad)",
    "pulse_sigma_s": "Pulse sigma (ns)",
    "pulse_center_s": "Pulse center (ns)",
    "freq_hz": "Frequency (MHz)",
    "phase_rad": "Phase (rad)",
    "amplitude": "Amplitude (DAC codes)",
    "encoding": "Sine encoding",
    "delay_s": "Burst delay (ns)",
    "duration_s": "Burst duration (ns)",
    "start": "Golden start code",
}
FIELD_DISPLAY_LABELS = {
    "quantum_gate": "Quantum gate",
}

FIELD_HELP_TEXTS = {
    "quantum_gate": "X=I, Y=Q+90deg, Z=paired phase",
}


def _field_display_label(field_name: str) -> str:
    return FIELD_DISPLAY_LABELS.get(field_name, LABELS[field_name])


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


class WaveformSenderApp(ttk.Frame):
    def __init__(self, master: tk.Tk):
        super().__init__(master, padding=18)
        self.root = master
        self.controller = model.WaveformController()
        self.messages: queue.Queue[tuple[str, object]] = queue.Queue()
        self._preview_binder: DebouncedPreviewBinder | None = None
        self._build_variables()
        self._configure_style()
        self._build_widgets()
        self._set_channel_fields("ch1")
        self._set_channel_fields("ch2")
        self._preview_binder = DebouncedPreviewBinder(self, self._preview_variables(), self._preview_from_live_edit)
        self.preview_waveforms()
        self.after(100, self._drain_messages)

    def _build_variables(self) -> None:
        defaults = model.WaveformConfig()
        connection = model.ConnectionConfig()
        self.output_dir = tk.StringVar(value=str(defaults.output_dir))
        self.ip = tk.StringVar(value=connection.ip)
        self.port = tk.StringVar(value=str(connection.port))
        self.udp_interface = tk.StringVar(value=connection.udp_interface)
        self.udp_source_ip = tk.StringVar(value=connection.udp_source_ip)
        self.timeout_s = tk.StringVar(value=str(connection.timeout_s))
        self.post_upload_sleep_s = tk.StringVar(value=str(connection.post_upload_sleep_s))
        self.sample_rate_hz = tk.StringVar(value=to_display_gsps(defaults.sample_rate_hz))
        self.loop = tk.BooleanVar(value=defaults.loop)
        self.wait_for_trigger = tk.BooleanVar(value=defaults.wait_for_trigger)
        self.dry_run = tk.BooleanVar(value=True)
        self.channel_type = {
            "ch1": tk.StringVar(value=defaults.mode),
            "ch2": tk.StringVar(value=defaults.mode),
        }
        self.channel_fields = {
            "ch1": {
                "quantum_gate": tk.StringVar(value="x"),
                "rotation_angle_rad": tk.StringVar(value="3.141592653589793"),
                "freq_hz": tk.StringVar(value=to_display_mhz(defaults.x_freq_hz)),
                "phase_rad": tk.StringVar(value=f"{defaults.x_phase_rad:g}"),
                "amplitude": tk.StringVar(value=str(defaults.amplitude)),
                "encoding": tk.StringVar(value=defaults.encoding),
                "delay_s": tk.StringVar(value=to_display_ns(defaults.x_delay_s)),
                "duration_s": tk.StringVar(value=to_display_ns(defaults.duration_s)),
                "pulse_preset": tk.StringVar(value=defaults.pulse_preset),
                "pulse_sigma_s": tk.StringVar(value=to_display_ns(defaults.pulse_sigma_s)),
                "pulse_center_s": tk.StringVar(value=to_display_ns(defaults.pulse_center_s)),
                "start": tk.StringVar(value=str(defaults.x_start)),
            },
            "ch2": {
                "quantum_gate": tk.StringVar(value="y"),
                "rotation_angle_rad": tk.StringVar(value="3.141592653589793"),
                "freq_hz": tk.StringVar(value=to_display_mhz(defaults.y_freq_hz)),
                "phase_rad": tk.StringVar(value=f"{defaults.y_phase_rad:g}"),
                "amplitude": tk.StringVar(value=str(defaults.amplitude)),
                "encoding": tk.StringVar(value=defaults.encoding),
                "delay_s": tk.StringVar(value=to_display_ns(defaults.y_delay_s)),
                "duration_s": tk.StringVar(value=to_display_ns(defaults.duration_s)),
                "pulse_preset": tk.StringVar(value="y"),
                "pulse_sigma_s": tk.StringVar(value=to_display_ns(defaults.pulse_sigma_s)),
                "pulse_center_s": tk.StringVar(value=to_display_ns(defaults.pulse_center_s)),
                "start": tk.StringVar(value=hex(defaults.y_start)),
            },
        }

    def _configure_style(self) -> None:
        self.root.title("RFSoC Waveform Sender")
        self.root.geometry("1180x760")
        self.root.minsize(WINDOW_MIN_WIDTH_PX, WINDOW_MIN_HEIGHT_PX)
        self.root.configure(background="#0f172a")
        style = ttk.Style(self.root)
        style.theme_use("clam")
        style.configure("TFrame", background="#0f172a")
        style.configure("Card.TFrame", background="#172033", relief="flat")
        style.configure("TLabel", background="#0f172a", foreground="#dbeafe", font=("TkDefaultFont", 10))
        style.configure("Card.TLabel", background="#172033", foreground="#dbeafe", font=("TkDefaultFont", 10))
        style.configure("Title.TLabel", background="#0f172a", foreground="#f8fafc", font=("TkDefaultFont", 20, "bold"))
        style.configure("Hint.TLabel", background="#0f172a", foreground="#94a3b8", font=("TkDefaultFont", 10))
        style.configure("Accent.TButton", background="#38bdf8", foreground="#082f49", font=("TkDefaultFont", 10, "bold"))
        style.map("Accent.TButton", background=[("active", "#7dd3fc")])
        style.configure("TButton", padding=(10, 6))
        style.configure("TEntry", fieldbackground="#e2e8f0", foreground="#0f172a")
        style.configure("TCombobox", fieldbackground="#e2e8f0", foreground="#0f172a")
        style.configure("TCheckbutton", background="#172033", foreground="#dbeafe")
        style.map(
            "TCheckbutton",
            background=[("active", "#172033"), ("selected", "#172033"), ("!disabled", "#172033")],
            foreground=[("active", "#dbeafe"), ("selected", "#dbeafe"), ("!disabled", "#dbeafe"), ("disabled", "#64748b")],
            indicatorcolor=[("selected", "#38bdf8"), ("!selected", "#0f172a")],
        )

    def _build_widgets(self) -> None:
        self.grid(row=0, column=0, sticky="nsew")
        self.root.rowconfigure(0, weight=1)
        self.root.columnconfigure(0, weight=1)
        self.columnconfigure(0, weight=0)
        self.columnconfigure(1, weight=1)
        self.rowconfigure(1, weight=1)

        ttk.Label(self, text="RFSoC Waveform Sender", style="Title.TLabel").grid(row=0, column=0, columnspan=2, sticky="w")
        ttk.Label(
            self,
            text="CH1 maps to DDR X and CH2 maps to DDR Y. Configure, preview, save, dry-run safely, or upload both channels.",
            style="Hint.TLabel",
        ).grid(row=0, column=1, sticky="e", padx=(20, 0))

        controls_shell = ttk.Frame(self, style="Card.TFrame")
        controls_shell.grid(row=1, column=0, sticky="nsw", pady=(16, 0), padx=(0, 16))
        controls_shell.rowconfigure(0, weight=1)
        controls_shell.columnconfigure(0, weight=1)

        self.controls_canvas = tk.Canvas(
            controls_shell,
            width=CONTROL_PANEL_WIDTH_PX,
            background="#172033",
            borderwidth=0,
            highlightthickness=0,
            yscrollincrement=24,
        )
        controls_scrollbar = ttk.Scrollbar(controls_shell, orient="vertical", command=self.controls_canvas.yview)
        self.controls_canvas.configure(yscrollcommand=controls_scrollbar.set)
        self.controls_canvas.grid(row=0, column=0, sticky="nsew")
        controls_scrollbar.grid(row=0, column=1, sticky="ns")

        controls = ttk.Frame(self.controls_canvas, style="Card.TFrame", padding=16)
        controls_window = self.controls_canvas.create_window((0, 0), window=controls, anchor="nw")
        controls.bind(
            "<Configure>",
            lambda _event: self.controls_canvas.configure(scrollregion=self.controls_canvas.bbox("all")),
        )
        self.controls_canvas.bind(
            "<Configure>",
            lambda event: self.controls_canvas.itemconfigure(controls_window, width=event.width),
        )
        self._bind_control_mousewheel(self.controls_canvas)
        controls.columnconfigure(1, weight=1)

        self._add_section_label(controls, "Target Connection", 0)
        self._add_entry(controls, "Board IP", self.ip, 1)
        self._add_entry(controls, "UDP port", self.port, 2)
        self._add_entry(controls, "UDP interface", self.udp_interface, 3)
        self._add_entry(controls, "Source IP", self.udp_source_ip, 4)
        self._add_entry(controls, "Timeout (s)", self.timeout_s, 5)
        self._add_entry(controls, "Post-upload sleep (s)", self.post_upload_sleep_s, 6)

        self._add_section_label(controls, "Global Playback", 7)
        self._add_entry(controls, GLOBAL_SAMPLE_RATE_LABEL, self.sample_rate_hz, 8)
        ttk.Checkbutton(controls, text="Loop playback", variable=self.loop).grid(row=9, column=0, columnspan=2, sticky="w", pady=(8, 0))
        ttk.Checkbutton(controls, text="Wait for trigger", variable=self.wait_for_trigger).grid(row=10, column=0, columnspan=2, sticky="w")
        ttk.Checkbutton(controls, text="Dry run, do not send UDP", variable=self.dry_run).grid(row=11, column=0, columnspan=2, sticky="w")

        self.channel_frames = {}
        self._build_channel_panel(controls, "ch1", "CH1 / DDR X", 12)
        self._build_channel_panel(controls, "ch2", "CH2 / DDR Y", 14)

        self._add_section_label(controls, "Artifacts", 16)
        self._add_entry(controls, "Output dir", self.output_dir, 17)
        ttk.Button(controls, text="Browse", command=self._browse_output_dir).grid(row=18, column=1, sticky="e", pady=(0, 8))

        button_bar = ttk.Frame(controls, style="Card.TFrame")
        button_bar.grid(row=19, column=0, columnspan=2, sticky="ew", pady=(8, 0))
        for column in range(ACTION_BUTTON_GRID_COLUMNS):
            button_bar.columnconfigure(column, weight=1, uniform="actions")
        button_specs = (
            (ACTION_BUTTONS[0], self.preview_waveforms, "Accent.TButton"),
            (ACTION_BUTTONS[1], self.test_connection, "TButton"),
            (ACTION_BUTTONS[2], self.save_or_dry_run, "TButton"),
            (ACTION_BUTTONS[3], self.send_to_board, "TButton"),
        )
        for index, (label, command, style_name) in enumerate(button_specs):
            ttk.Button(button_bar, text=label, style=style_name, command=command).grid(
                row=index // ACTION_BUTTON_GRID_COLUMNS,
                column=index % ACTION_BUTTON_GRID_COLUMNS,
                sticky=ACTION_BUTTON_GRID_STICKY,
                padx=(0, 8) if index % ACTION_BUTTON_GRID_COLUMNS == 0 else (0, 0),
                pady=(0, 8) if index < ACTION_BUTTON_GRID_COLUMNS else (0, 0),
            )

        right = ttk.Frame(self, style="Card.TFrame", padding=16)
        right.grid(row=1, column=1, sticky="nsew", pady=(16, 0))
        right.rowconfigure(0, weight=3)
        right.rowconfigure(1, weight=1)
        right.columnconfigure(0, weight=1)

        self.figure = Figure(figsize=(7, 4.8), dpi=100, facecolor="#172033")
        self.ax_x = cast(Any, self.figure.add_subplot(211))
        self.ax_y = cast(Any, self.figure.add_subplot(212, sharex=self.ax_x))
        self.canvas = FigureCanvasTkAgg(self.figure, master=right)
        self.canvas.get_tk_widget().grid(row=0, column=0, sticky="nsew")

        self.log = scrolledtext.ScrolledText(right, height=9, bg="#020617", fg="#dbeafe", insertbackground="#dbeafe")
        self.log.grid(row=1, column=0, sticky="nsew", pady=(14, 0))
        self._append_log("Ready. Dry run is enabled by default.")

    def _bind_control_mousewheel(self, canvas: tk.Canvas) -> None:
        def scroll_units(event: tk.Event) -> int:
            if getattr(event, "num", None) == 4:
                return -3
            if getattr(event, "num", None) == 5:
                return 3
            return -1 * int(getattr(event, "delta", 0) / 120)

        def on_mousewheel(event: tk.Event) -> str:
            units = scroll_units(event)
            if units:
                canvas.yview_scroll(units, "units")
            return "break"

        canvas.bind("<Enter>", lambda _event: canvas.bind_all("<MouseWheel>", on_mousewheel))
        canvas.bind("<Leave>", lambda _event: canvas.unbind_all("<MouseWheel>"))
        canvas.bind("<Enter>", lambda _event: canvas.bind_all("<Button-4>", on_mousewheel), add="+")
        canvas.bind("<Leave>", lambda _event: canvas.unbind_all("<Button-4>"), add="+")
        canvas.bind("<Enter>", lambda _event: canvas.bind_all("<Button-5>", on_mousewheel), add="+")
        canvas.bind("<Leave>", lambda _event: canvas.unbind_all("<Button-5>"), add="+")

    def _add_section_label(self, parent: ttk.Frame, text: str, row: int) -> None:
        ttk.Label(parent, text=text, style="Card.TLabel", font=("TkDefaultFont", 11, "bold")).grid(
            row=row, column=0, columnspan=2, sticky="w", pady=(14, 6)
        )

    def _add_entry(self, parent: ttk.Frame, label: str, variable: tk.StringVar, row: int) -> None:
        ttk.Label(parent, text=label, style="Card.TLabel", wraplength=180).grid(row=row, column=0, sticky="w", pady=4, padx=(0, 10))
        ttk.Entry(parent, textvariable=variable, width=22).grid(row=row, column=1, sticky="ew", pady=4)

    def _build_channel_panel(self, parent: ttk.Frame, channel: str, title: str, row: int) -> None:
        self._add_section_label(parent, title, row)
        frame = ttk.Frame(parent, style="Card.TFrame")
        frame.grid(row=row + 1, column=0, columnspan=2, sticky="ew", pady=(0, 4))
        frame.columnconfigure(1, weight=1)
        self.channel_frames[channel] = frame
        ttk.Label(frame, text="Type", style="Card.TLabel").grid(row=0, column=0, sticky="w", pady=4, padx=(0, 10))
        menu = ttk.Combobox(frame, textvariable=self.channel_type[channel], values=WAVEFORM_TYPES, state="readonly", width=18)
        menu.grid(row=0, column=1, sticky="ew", pady=4)
        self._disable_combobox_mousewheel(menu)
        menu.bind("<<ComboboxSelected>>", lambda _event, channel=channel: self._set_channel_fields(channel))

    def _disable_combobox_mousewheel(self, combobox: ttk.Combobox) -> None:
        for event_name in COMBOBOX_WHEEL_BLOCK_EVENTS:
            combobox.bind(event_name, _block_combobox_mousewheel)

    def _set_channel_fields(self, channel: str) -> None:
        frame = self.channel_frames[channel]
        for child in frame.grid_slaves():
            info = child.grid_info()
            if int(info.get("row", 0)) > 0:
                child.destroy()
        fields = CHANNEL_FIELD_GROUPS[self.channel_type[channel].get()]
        if not fields:
            ttk.Label(frame, text="Outputs zero samples.", style="Card.TLabel").grid(row=1, column=0, columnspan=2, sticky="w", pady=4)
        for row_offset, field_name in enumerate(fields, start=1):
            ttk.Label(frame, text=_field_display_label(field_name), style="Card.TLabel", wraplength=180).grid(
                row=row_offset, column=0, sticky="w", pady=4, padx=(0, 10)
            )
            variable = self.channel_fields[channel][field_name]
            if field_name == "encoding":
                encoding_menu = ttk.Combobox(
                    frame,
                    textvariable=variable,
                    values=("signed", "offset-binary"),
                    state="readonly",
                    width=18,
                )
                encoding_menu.grid(row=row_offset, column=1, sticky="ew", pady=4)
                self._disable_combobox_mousewheel(encoding_menu)
            elif field_name == "quantum_gate":
                quantum_gate_row = ttk.Frame(frame, style="Card.TFrame")
                quantum_gate_row.grid(row=row_offset, column=1, sticky="ew", pady=4)
                quantum_gate_row.columnconfigure(0, weight=1)
                quantum_gate_menu = ttk.Combobox(
                    quantum_gate_row,
                    textvariable=variable,
                    values=("x", "y", "z"),
                    state="readonly",
                    width=18,
                )
                quantum_gate_menu.grid(row=0, column=0, sticky="ew")
                self._disable_combobox_mousewheel(quantum_gate_menu)
                ttk.Label(
                    quantum_gate_row,
                    text=FIELD_HELP_TEXTS[field_name],
                    style="Card.TLabel",
                    wraplength=180,
                ).grid(row=1, column=0, sticky="w", pady=(3, 0))
            else:
                ttk.Entry(frame, textvariable=variable, width=22).grid(row=row_offset, column=1, sticky="ew", pady=4)
        if self._preview_binder is not None:
            self._preview_binder.schedule()

    def _browse_output_dir(self) -> None:
        selected = filedialog.askdirectory(initialdir=self.output_dir.get() or str(Path.home()))
        if selected:
            self.output_dir.set(selected)

    def _parse_int(self, value: str) -> int:
        return int(value.strip(), 0)

    def _preview_variables(self) -> list[Any]:
        variables: list[Any] = [self.sample_rate_hz, self.loop, self.wait_for_trigger, self.dry_run]
        variables.extend(self.channel_type.values())
        for channel_fields in self.channel_fields.values():
            variables.extend(channel_fields.values())
        return variables

    def _collect_channel_config(self, channel: str) -> model.ChannelWaveformConfig:
        fields = self.channel_fields[channel]
        return model.ChannelWaveformConfig(
            waveform_type=self.channel_type[channel].get(),
            quantum_gate=fields["quantum_gate"].get(),
            rotation_angle_rad=float(fields["rotation_angle_rad"].get()),
            freq_hz=from_display_mhz(fields["freq_hz"].get()),
            phase_rad=float(fields["phase_rad"].get()),
            amplitude=self._parse_int(fields["amplitude"].get()),
            encoding=fields["encoding"].get(),
            delay_s=from_display_ns(fields["delay_s"].get()),
            duration_s=from_display_ns(fields["duration_s"].get()),
            pulse_preset=fields["pulse_preset"].get(),
            pulse_sigma_s=from_display_ns(fields["pulse_sigma_s"].get()),
            pulse_center_s=from_display_ns(fields["pulse_center_s"].get()),
            start=self._parse_int(fields["start"].get()),
        )

    def _collect_config(self, dry_run: bool | None = None) -> model.WaveformConfig:
        return model.WaveformConfig(
            mode="per-channel",
            output_dir=Path(self.output_dir.get()).expanduser(),
            sample_rate_hz=from_display_gsps(self.sample_rate_hz.get()),
            loop=bool(self.loop.get()),
            wait_for_trigger=bool(self.wait_for_trigger.get()),
            dry_run=bool(self.dry_run.get() if dry_run is None else dry_run),
            ch1=self._collect_channel_config("ch1"),
            ch2=self._collect_channel_config("ch2"),
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

    def preview_waveforms(self) -> None:
        try:
            generated = model.generate_waveforms(self._collect_config(dry_run=True))
            self._draw_preview(generated)
            self._append_log(model.summarize_waveform("Preview CH1", generated.x))
            self._append_log(model.summarize_waveform("Preview CH2", generated.y))
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
        for axis, title, wave, color in (
            (self.ax_x, PREVIEW_TITLES[0], generated.x, "#38bdf8"),
            (self.ax_y, PREVIEW_TITLES[1], generated.y, "#f97316"),
        ):
            axis.clear()
            indices, values = model.preview_series(wave)
            axis.plot(indices, values, color=color, linewidth=1.5)
            axis.set_title(title, color="#f8fafc")
            axis.set_ylabel("DAC code", color="#cbd5e1")
            axis.grid(True, color="#334155", linewidth=0.6, alpha=0.8)
            axis.tick_params(colors="#cbd5e1")
            axis.set_facecolor("#0f172a")
        self.ax_y.set_xlabel("Sample index", color="#cbd5e1")
        self.figure.tight_layout()
        self.canvas.draw_idle()

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
            else:
                self._append_log(f"operation failed: {payload}")
                messagebox.showerror("Operation failed", str(payload))
        self.after(100, self._drain_messages)

    def _append_log(self, text: str) -> None:
        self.log.insert("end", text + "\n")
        self.log.see("end")


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
