"""Reusable Tk view components for the RFSoC waveform sender GUI."""

from __future__ import annotations
from dataclasses import dataclass
from typing import Any, Callable, Sequence, cast
import tkinter as tk
from tkinter import scrolledtext, ttk

from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg
from matplotlib.figure import Figure
import numpy as np


PREVIEW_MARGIN_FRACTION = 0.08
PREVIEW_MIN_MARGIN_NS = 20.0
PREVIEW_MIN_WINDOW_NS = 200.0


@dataclass(frozen=True, slots=True)
class FieldSpec:
    label: str
    key: str


@dataclass(frozen=True, slots=True)
class SectionSpec:
    title: str
    fields: tuple[FieldSpec, ...]


class ScrollableNotebook:
    def __init__(self, parent: tk.Widget, tabs: Sequence[str], width: int, card_color: str, scrollbar_markers: tuple[str, ...]):
        self.notebook = ttk.Notebook(parent, width=width)
        self.notebook.grid(row=0, column=0, sticky="nsew")
        self.canvases: list[tk.Canvas] = []
        self.scrollbar_markers = scrollbar_markers
        self.tabs = {title: self._add_tab(title, width, card_color) for title in tabs}

    def _add_tab(self, title: str, width: int, card_color: str) -> ttk.Frame:
        tab_shell = ttk.Frame(self.notebook, style="Card.TFrame")
        tab_shell.rowconfigure(0, weight=1)
        tab_shell.columnconfigure(0, weight=1)
        self.notebook.add(tab_shell, text=title)

        canvas = tk.Canvas(
            tab_shell,
            width=width,
            background=card_color,
            borderwidth=0,
            highlightthickness=0,
            yscrollincrement=24,
        )
        scrollbar = ttk.Scrollbar(tab_shell, orient="vertical", command=canvas.yview)
        canvas.configure(yscrollcommand=scrollbar.set)
        canvas.grid(row=0, column=0, sticky="nsew")
        scrollbar.grid(row=0, column=1, sticky="ns")

        controls = ttk.Frame(canvas, style="Card.TFrame", padding=16)
        controls_window = canvas.create_window((0, 0), window=controls, anchor="nw")
        controls.bind("<Configure>", lambda _event: canvas.configure(scrollregion=canvas.bbox("all")))
        canvas.bind("<Configure>", lambda event: canvas.itemconfigure(controls_window, width=event.width))
        self._bind_control_mousewheel(canvas)
        self.canvases.append(canvas)
        controls.columnconfigure(1, weight=1)
        return controls

    def __getitem__(self, title: str) -> ttk.Frame:
        return self.tabs[title]

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


class ParameterForm:
    def __init__(self, parent: ttk.Frame):
        self.parent = parent

    def section(self, text: str, row: int) -> None:
        ttk.Label(self.parent, text=text, style="Section.TLabel").grid(
            row=row,
            column=0,
            columnspan=2,
            sticky="w",
            pady=(16, 6),
        )

    def entry(self, label: str, variable: tk.StringVar, row: int) -> ttk.Entry:
        grid_field_label(self.parent, label, row, wraplength=190)
        entry = ttk.Entry(self.parent, textvariable=variable, width=22)
        entry.grid(row=row, column=1, sticky="ew", pady=4)
        return entry

    def combobox(self, label: str, variable: tk.StringVar, values: Sequence[str], row: int, bind_wheel_blocker: Callable[[ttk.Combobox], None]) -> ttk.Combobox:
        ttk.Label(self.parent, text=label, style="Card.TLabel", wraplength=190).grid(row=row, column=0, sticky="w", pady=4, padx=(0, 10))
        combo = ttk.Combobox(self.parent, textvariable=variable, values=values, state="readonly", width=20)
        combo.grid(row=row, column=1, sticky="ew", pady=4)
        bind_wheel_blocker(combo)
        return combo

    def checkbutton(self, label: str, variable: tk.BooleanVar, row: int) -> ttk.Checkbutton:
        button = ttk.Checkbutton(self.parent, text=label, variable=variable)
        button.grid(row=row, column=0, columnspan=2, sticky="w", pady=(8, 0))
        return button

    def browse_row(self, command: Callable[[], None], row: int) -> ttk.Button:
        button = ttk.Button(self.parent, text="Browse", command=command)
        button.grid(row=row, column=1, sticky="e", pady=(0, 8))
        return button

    def section_fields(self, section: SectionSpec, variables: dict[str, tk.StringVar], start_row: int) -> int:
        self.section(section.title, start_row)
        row = start_row + 1
        for field in section.fields:
            self.entry(field.label, variables[field.key], row)
            row += 1
        return row


def grid_field_label(parent: ttk.Frame, label: str, row: int, wraplength: int = 190) -> ttk.Label:
    label_widget = ttk.Label(parent, text=label, style="Card.TLabel", wraplength=wraplength)
    label_widget.grid(row=row, column=0, sticky="w", pady=4, padx=(0, 10))
    return label_widget


class RunConsole(ttk.Frame):
    def __init__(self, parent: tk.Widget, action_specs: Sequence[tuple[str, Callable[[], None], str]], log_background: str, text_color: str):
        super().__init__(parent, style="Card.TFrame", padding=14)
        self.rowconfigure(2, weight=1)
        self.columnconfigure(0, weight=1)
        ttk.Label(self, text="Run", style="PanelTitle.TLabel").grid(row=0, column=0, sticky="w")
        action_frame = ttk.Frame(self, style="Card.TFrame")
        action_frame.grid(row=1, column=0, sticky="ew", pady=(10, 12))
        action_frame.columnconfigure(0, weight=1)
        for row, (label, command, style_name) in enumerate(action_specs):
            ttk.Button(action_frame, text=label, style=style_name, command=command).grid(row=row, column=0, sticky="ew", pady=(0, 8))
        self.log = scrolledtext.ScrolledText(self, width=38, height=22, bg=log_background, fg=text_color, insertbackground=text_color)
        self.log.grid(row=2, column=0, sticky="nsew")

    def append(self, text: str) -> None:
        self.log.insert("end", text + "\n")
        self.log.see("end")


def _iq_view(wave: Any) -> np.ndarray:
    samples = np.asarray(wave, dtype=np.int16)
    if samples.size < 2:
        return np.zeros((0, 2), dtype=np.int16)
    return samples[: samples.size - (samples.size % 2)].reshape(-1, 2)


def preview_time_window_ns(waves: Sequence[Any], sample_rate_hz: float) -> tuple[float, float]:
    sample_rate = max(float(sample_rate_hz), 1.0)
    sample_ns = 1e9 / sample_rate
    total_complex = 0
    first_active: int | None = None
    last_active: int | None = None
    for wave in waves:
        iq = _iq_view(wave)
        total_complex = max(total_complex, int(iq.shape[0]))
        if iq.size == 0:
            continue
        activity = np.abs(iq[:, 0].astype(np.int32)) + np.abs(iq[:, 1].astype(np.int32))
        active = np.flatnonzero(activity)
        if active.size == 0:
            continue
        first = int(active[0])
        last = int(active[-1])
        first_active = first if first_active is None else min(first_active, first)
        last_active = last if last_active is None else max(last_active, last)

    total_duration_ns = total_complex * sample_ns
    if first_active is None or last_active is None:
        right = min(max(total_duration_ns, sample_ns), 1_000.0)
        return 0.0, max(right, sample_ns)

    start_ns = first_active * sample_ns
    end_ns = (last_active + 1) * sample_ns
    span_ns = max(end_ns - start_ns, sample_ns)
    min_window_ns = max(PREVIEW_MIN_WINDOW_NS, sample_ns * 8.0)
    if span_ns < min_window_ns:
        center_ns = 0.5 * (start_ns + end_ns)
        start_ns = center_ns - (0.5 * min_window_ns)
        end_ns = center_ns + (0.5 * min_window_ns)
        span_ns = min_window_ns
    margin_ns = max(PREVIEW_MIN_MARGIN_NS, span_ns * PREVIEW_MARGIN_FRACTION, sample_ns * 4.0)
    left_ns = max(0.0, start_ns - margin_ns)
    right_ns = end_ns + margin_ns
    if total_duration_ns > 0.0:
        right_ns = min(right_ns, total_duration_ns)
    if right_ns <= left_ns:
        right_ns = left_ns + sample_ns
    return left_ns, right_ns


class PreviewWorkbench(ttk.Frame):
    def __init__(self, parent: tk.Widget, card_color: str, colors: tuple[str, ...], sample_rate_fallback_hz: float):
        super().__init__(parent, style="Card.TFrame", padding=14)
        self.colors = colors
        self.sample_rate_fallback_hz = sample_rate_fallback_hz
        self.rowconfigure(1, weight=1)
        self.columnconfigure(0, weight=1)
        ttk.Label(self, text="Pulse / IQ Preview", style="PanelTitle.TLabel").grid(row=0, column=0, sticky="w")
        self.figure = Figure(figsize=(8.4, 8.2), dpi=100, facecolor=card_color)
        grid = self.figure.add_gridspec(3, 1, height_ratios=[1.0, 2.0, 1.2])
        self.timeline_axis = cast(Any, self.figure.add_subplot(grid[0, 0]))
        self.wave_axis = cast(Any, self.figure.add_subplot(grid[1, 0]))
        self.fft_axis = cast(Any, self.figure.add_subplot(grid[2, 0]))
        self.axes = [self.timeline_axis, self.wave_axis, self.fft_axis]
        self.canvas = FigureCanvasTkAgg(self.figure, master=self)
        self.canvas.get_tk_widget().grid(row=1, column=0, sticky="nsew", pady=(10, 0))

    def draw(self, generated: Any) -> None:
        waves = (generated.x, generated.y, generated.ch3, generated.ch4, generated.ch5, generated.ch6, generated.ch7, generated.ch8)
        sample_rate_hz = float(generated.metadata.get("sample_rate_hz", self.sample_rate_fallback_hz))
        time_window_ns = preview_time_window_ns(waves, sample_rate_hz)
        self._draw_timeline(waves, sample_rate_hz, time_window_ns)
        self._draw_time_waveforms(waves, sample_rate_hz, time_window_ns)
        self._draw_fft(waves, sample_rate_hz)
        self.figure.tight_layout()
        self.canvas.draw_idle()

    def _style_axis(self, axis: Any) -> None:
        axis.grid(True, color="#334155", linewidth=0.6, alpha=0.8)
        axis.tick_params(colors="#cbd5e1")
        axis.set_facecolor("#0f172a")
        axis.title.set_color("#f8fafc")
        axis.xaxis.label.set_color("#cbd5e1")
        axis.yaxis.label.set_color("#cbd5e1")

    def _draw_timeline(self, waves: tuple[Any, ...], sample_rate_hz: float, time_window_ns: tuple[float, float]) -> None:
        axis = self.timeline_axis
        axis.clear()
        for index, (wave, color) in enumerate(zip(waves, self.colors, strict=True)):
            iq = _iq_view(wave)
            activity = np.abs(iq[:, 0].astype(np.int32)) + np.abs(iq[:, 1].astype(np.int32))
            active = np.flatnonzero(activity)
            y = len(waves) - index
            if active.size:
                start_ns = active[0] / sample_rate_hz * 1e9
                width_ns = max(1.0 / sample_rate_hz * 1e9, (active[-1] - active[0] + 1) / sample_rate_hz * 1e9)
                axis.broken_barh([(start_ns, width_ns)], (y - 0.34, 0.68), facecolors=color, edgecolors=color, alpha=0.9)
            else:
                axis.broken_barh([(0.0, 1.0)], (y - 0.18, 0.36), facecolors="#475569", edgecolors="#475569", alpha=0.45)
        axis.set_yticks(range(1, len(waves) + 1), [f"CH{idx}" for idx in range(len(waves), 0, -1)])
        axis.set_title("Pulse Timeline")
        axis.set_xlabel("Time (ns)")
        axis.set_ylabel("Channel")
        axis.set_xlim(*time_window_ns)
        self._style_axis(axis)

    def _draw_time_waveforms(self, waves: tuple[Any, ...], sample_rate_hz: float, time_window_ns: tuple[float, float]) -> None:
        axis = self.wave_axis
        axis.clear()
        max_complex = 768
        sample_rate = max(float(sample_rate_hz), 1.0)
        start_index = max(0, int(np.floor(time_window_ns[0] * sample_rate / 1e9)))
        stop_index = max(start_index + 1, int(np.ceil(time_window_ns[1] * sample_rate / 1e9)))
        for index, (wave, color) in enumerate(zip(waves, self.colors, strict=True)):
            iq = _iq_view(wave)
            if iq.size == 0:
                continue
            clipped_stop = min(stop_index, int(iq.shape[0]))
            clipped_start = min(start_index, clipped_stop - 1)
            visible = iq[clipped_start:clipped_stop]
            step = max(1, int(np.ceil(visible.shape[0] / max_complex)))
            sampled = visible[::step, 0]
            sample_indices = np.arange(clipped_start, clipped_stop, step, dtype=np.float64)
            time_ns = sample_indices / sample_rate * 1e9
            axis.plot(time_ns, sampled, color=color, linewidth=1.15, label=f"CH{index + 1}")
        axis.set_title("I Lane Preview (active window)")
        axis.set_xlabel("Time (ns)")
        axis.set_ylabel("DAC code")
        axis.set_xlim(*time_window_ns)
        axis.legend(loc="upper right", ncol=4, fontsize=8, frameon=False, labelcolor="#dbeafe")
        self._style_axis(axis)

    def _draw_fft(self, waves: tuple[Any, ...], sample_rate_hz: float) -> None:
        axis = self.fft_axis
        axis.clear()
        selected_channel = 1
        selected = np.asarray(waves[0], dtype=np.int16)
        for index, wave in enumerate(waves, start=1):
            candidate = np.asarray(wave, dtype=np.int16)
            if np.any(candidate):
                selected_channel = index
                selected = candidate
                break
        iq = selected.reshape(-1, 2).astype(np.float64)
        if iq.shape[0] > 1 and np.any(iq):
            complex_wave = iq[:, 0] + (1j * iq[:, 1])
            window = np.hanning(complex_wave.size)
            spectrum = np.fft.fftshift(np.fft.fft(complex_wave * window))
            freqs_mhz = np.fft.fftshift(np.fft.fftfreq(complex_wave.size, d=1.0 / sample_rate_hz)) / 1e6
            mag_db = 20.0 * np.log10(np.maximum(np.abs(spectrum), 1.0))
            axis.plot(freqs_mhz, mag_db - np.max(mag_db), color=self.colors[selected_channel - 1], linewidth=1.2)
        axis.set_title(f"FFT Preview CH{selected_channel}")
        axis.set_xlabel("Baseband frequency (MHz)")
        axis.set_ylabel("dBc")
        self._style_axis(axis)
