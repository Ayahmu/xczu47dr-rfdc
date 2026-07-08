import os
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOFTWARE_DIR = ROOT / "software"
sys.path.insert(0, str(SOFTWARE_DIR))

import waveform_gui  # type: ignore[import-not-found]  # noqa: E402
import waveform_gui_view  # type: ignore[import-not-found]  # noqa: E402
import host  # type: ignore[import-not-found]  # noqa: E402


class WaveformGuiTests(unittest.TestCase):
    def test_preview_titles_use_channel_names(self):
        self.assertEqual(
            waveform_gui.PREVIEW_TITLES,
            (
                "CH1 XY lane0 vout00",
                "CH2 XY lane1 vout02",
                "CH3 XY lane2 vout10",
                "CH4 XY lane3 vout12",
                "CH5 Z lane4 vout20",
                "CH6 Z lane5 vout22",
                "CH7 Readout lane6 vout30",
                "CH8 Readout lane7 vout32",
            ),
        )
        self.assertEqual(waveform_gui.CHANNELS, ("ch1", "ch2", "ch3", "ch4", "ch5", "ch6", "ch7", "ch8"))
        self.assertEqual(len(waveform_gui.PREVIEW_COLORS), 8)

    def test_waveform_types_are_limited_to_iq_cw_iq_sine_and_gaussian_sine(self):
        self.assertEqual(waveform_gui.WAVEFORM_TYPES, ("dc-iq-cw", "iq-sine", "iq-gaussian-sine"))
        self.assertEqual(waveform_gui.DEFAULT_CHANNEL_WAVEFORM_TYPE, "dc-iq-cw")
        self.assertEqual(waveform_gui.WAVEFORM_TYPE_LABELS["dc-iq-cw"], "IQ CW")
        self.assertEqual(waveform_gui.WAVEFORM_TYPE_LABELS["iq-sine"], "IQ Sine")
        self.assertEqual(waveform_gui.WAVEFORM_TYPE_LABELS["iq-gaussian-sine"], "IQ Gaussian Sine")
        self.assertEqual(waveform_gui.EZQ_CHANNEL_WAVEFORMS, ("xy", "z", "readout"))
        self.assertEqual(waveform_gui.CHANNEL_FIELD_GROUPS["dc-iq-cw"], ("amplitude", "duration_s"))
        self.assertEqual(waveform_gui.CHANNEL_FIELD_GROUPS["iq-sine"], ("freq_hz", "phase_rad", "amplitude", "duration_s"))
        self.assertEqual(waveform_gui.CHANNEL_FIELD_GROUPS["iq-gaussian-sine"], ("freq_hz", "phase_rad", "amplitude", "duration_s"))
        self.assertNotIn("pypulse", waveform_gui.CHANNEL_FIELD_GROUPS)
        self.assertNotIn("quantum", waveform_gui.CHANNEL_FIELD_GROUPS)
        self.assertNotIn("sine", waveform_gui.CHANNEL_FIELD_GROUPS)
        xy_keys = tuple(field.key for field in waveform_gui.EZQ_CHANNEL_FIELD_GROUPS["xy"])
        z_keys = tuple(field.key for field in waveform_gui.EZQ_CHANNEL_FIELD_GROUPS["z"])
        readout_keys = tuple(field.key for field in waveform_gui.EZQ_CHANNEL_FIELD_GROUPS["readout"])
        self.assertIn("pi_amp", xy_keys)
        self.assertIn("z_gate_time_s", z_keys)
        self.assertIn("readout_flattop_s", readout_keys)
        self.assertEqual(xy_keys[0], "start_time_s")
        self.assertEqual(z_keys[0], "start_time_s")
        self.assertEqual(readout_keys[0], "start_time_s")
        self.assertNotIn("readout_freq_hz", z_keys)
        self.assertNotIn("z_amp", xy_keys)

    def test_ezq_xy_gate_fields_are_conditionally_visible(self):
        x_pi_keys = tuple(field.key for field in waveform_gui._ezq_xy_gate_fields("x_pi"))
        x_half_keys = tuple(field.key for field in waveform_gui._ezq_xy_gate_fields("x_half"))
        x12_keys = tuple(field.key for field in waveform_gui._ezq_xy_gate_fields("x12_pi"))
        spec_keys = tuple(field.key for field in waveform_gui._ezq_xy_gate_fields("spec"))

        self.assertEqual(x_pi_keys[0], "start_time_s")
        self.assertIn("pi_amp", x_pi_keys)
        self.assertNotIn("pi_amp_half", x_pi_keys)
        self.assertIn("pi_amp_half", x_half_keys)
        self.assertNotIn("pi_amp", x_half_keys)
        self.assertIn("f21_hz", x12_keys)
        self.assertIn("pi_amp21", x12_keys)
        self.assertNotIn("f10_hz", x12_keys)
        self.assertIn("spec_amp", spec_keys)
        self.assertIn("spec_len_s", spec_keys)
        self.assertNotIn("pi_amp", spec_keys)

    def test_ezq_z_shape_fields_hide_ripples_until_diabatic_mode(self):
        square_keys = tuple(field.key for field in waveform_gui._ezq_z_shape_fields("square"))
        diabatic_keys = tuple(field.key for field in waveform_gui._ezq_z_shape_fields("diabatic_cz"))

        self.assertEqual(square_keys[0], "start_time_s")
        self.assertIn("z_shape", square_keys)
        self.assertIn("z_amp", square_keys)
        self.assertNotIn("z_ripple0", square_keys)
        self.assertIn("z_ripple0", diabatic_keys)
        self.assertIn("z_ripple3", diabatic_keys)

    def test_gui_waveform_type_falls_back_for_legacy_modes(self):
        self.assertEqual(waveform_gui._gui_waveform_type("dc-iq-cw"), "dc-iq-cw")
        self.assertEqual(waveform_gui._gui_waveform_type("iq-sine"), "iq-sine")
        self.assertEqual(waveform_gui._gui_waveform_type("iq-gaussian-sine"), "iq-gaussian-sine")
        self.assertEqual(waveform_gui._gui_waveform_type("off"), "dc-iq-cw")
        self.assertEqual(waveform_gui._gui_waveform_type("sine"), "iq-sine")
        self.assertEqual(waveform_gui._gui_waveform_type("pypulse"), "iq-gaussian-sine")
        self.assertEqual(waveform_gui._gui_waveform_type("hls"), "iq-gaussian-sine")
        self.assertEqual(waveform_gui._gui_waveform_type("per-channel"), "dc-iq-cw")
        self.assertEqual(waveform_gui._gui_waveform_type("golden"), "dc-iq-cw")
        self.assertEqual(waveform_gui._gui_waveform_type(None), "dc-iq-cw")

    def test_engineering_unit_labels_hide_scientific_notation(self):
        self.assertEqual(waveform_gui.LABELS["freq_hz"], "IQ sine freq (MHz)")
        self.assertEqual(waveform_gui.LABELS["phase_rad"], "Phase (rad)")
        self.assertEqual(waveform_gui.LABELS["amplitude"], "Amplitude (DAC codes)")
        self.assertEqual(waveform_gui.LABELS["duration_s"], "Length (ns)")
        self.assertEqual(waveform_gui.GLOBAL_SAMPLE_RATE_LABEL, "IQ sample rate (GS/s)")
        self.assertEqual(waveform_gui.GLOBAL_RFDC_INTERPOLATION_LABEL, "RFDC interpolation (x)")

    def test_engineering_unit_conversions(self):
        self.assertEqual(waveform_gui.to_display_mhz(100e6), "100")
        self.assertEqual(waveform_gui.to_display_ns(120e-9), "120")
        self.assertEqual(waveform_gui.to_display_gsps(1.0e9), "1")
        self.assertEqual(waveform_gui.from_display_mhz("100"), 100e6)
        self.assertEqual(waveform_gui.from_display_ns("120"), 120e-9)
        self.assertEqual(waveform_gui.from_display_gsps("1"), 1.0e9)

    def test_left_controls_define_tabbed_container(self):
        self.assertEqual(waveform_gui.CONTROL_TABS, ("Setup", "Quantum", "Channels", "ILA Report"))
        self.assertEqual(
            waveform_gui.CONTROL_TAB_MARKERS,
            ("ttk.Notebook", "Setup", "Quantum", "Channels", "ILA Report"),
        )
        self.assertEqual(waveform_gui.WAVEFORM_SOURCE_MODES, ("ezq-quantum", "manual-channels"))

    def test_control_tabs_keep_scrollable_content_regions(self):
        self.assertEqual(
            waveform_gui.CONTROL_SCROLLBAR_MARKERS,
            ("tk.Canvas", "ttk.Scrollbar", "yscrollcommand", "<MouseWheel>"),
        )

    def test_action_buttons_include_connection_test_and_send(self):
        self.assertEqual(
            waveform_gui.ACTION_BUTTONS,
            ("Preview", "Test Connection", "Save / Dry Run", "Send to Board"),
        )
        self.assertEqual(waveform_gui.SEND_CONFIRMATION_TITLE, "Confirm send to board")

    def test_ila_program_modes_default_to_never(self):
        self.assertEqual(waveform_gui.ILA_PROGRAM_MODES, ("never", "auto", "always"))
        self.assertEqual(waveform_gui.DEFAULT_ILA_PROGRAM_MODE, "never")
        self.assertEqual(waveform_gui.ILA_CAPTURE_BUTTON_TEXT, "Run ILA Capture + Report")

    def test_action_buttons_fit_left_control_panel(self):
        self.assertLessEqual(waveform_gui.ACTION_BUTTON_GRID_COLUMNS, 2)
        self.assertEqual(len(waveform_gui.ACTION_BUTTONS), 4)
        self.assertGreaterEqual(waveform_gui.CONTROL_PANEL_WIDTH_PX, 420)
        self.assertGreaterEqual(
            waveform_gui.CONTROL_PANEL_WIDTH_PX,
            waveform_gui.ACTION_BUTTON_GRID_COLUMNS * waveform_gui.ACTION_BUTTON_MIN_WIDTH_PX,
        )

    def test_preview_time_window_follows_active_waveform_region(self):
        wave = [0] * (10_000 * 2)
        for complex_index in range(100, 220):
            wave[complex_index * 2] = 1000

        left_ns, right_ns = waveform_gui_view.preview_time_window_ns([wave], 1.0e9)

        self.assertLess(left_ns, 100.0)
        self.assertGreater(right_ns, 220.0)
        self.assertLess(right_ns, 1_000.0)

    def test_preview_time_window_uses_short_default_for_empty_record(self):
        wave = [0] * (10_000 * 2)

        self.assertEqual(waveform_gui_view.preview_time_window_ns([wave], 1.0e9), (0.0, 1_000.0))

    def test_gui_field_labels_are_limited_to_iq_controls(self):
        self.assertEqual(set(waveform_gui.LABELS), {"freq_hz", "phase_rad", "amplitude", "duration_s"})
        self.assertEqual(waveform_gui._field_display_label("freq_hz"), "IQ sine freq (MHz)")

    def test_combobox_mousewheel_events_are_blocked(self):
        self.assertEqual(waveform_gui.COMBOBOX_WHEEL_BLOCK_EVENTS, ("<MouseWheel>", "<Button-4>", "<Button-5>"))
        self.assertEqual(waveform_gui._block_combobox_mousewheel(object()), "break")

    def test_live_preview_binder_debounces_variable_changes_without_display(self):
        calls = []
        scheduled = []

        class FakeVariable:
            def __init__(self):
                self.callbacks = []

            def trace_add(self, mode, callback):
                self.callbacks.append((mode, callback))
                return f"trace-{len(self.callbacks)}"

        class FakeScheduler:
            def after(self, delay_ms, callback):
                scheduled.append((delay_ms, callback))
                return f"after-{len(scheduled)}"

            def after_cancel(self, token):
                calls.append(("cancel", token))

        variables = [FakeVariable(), FakeVariable()]
        binder = waveform_gui.DebouncedPreviewBinder(
            scheduler=FakeScheduler(),
            variables=variables,
            callback=lambda: calls.append("preview"),
            delay_ms=175,
        )

        variables[0].callbacks[0][1]("var", "", "write")
        variables[1].callbacks[0][1]("var", "", "write")

        self.assertEqual(scheduled[0][0], 175)
        self.assertEqual(scheduled[1][0], 175)
        self.assertIn(("cancel", "after-1"), calls)
        scheduled[-1][1]()
        self.assertIn("preview", calls)
        self.assertIsNone(binder.pending_after_id)

    def test_auto_save_binder_debounces_variable_changes_without_display(self):
        calls = []
        scheduled = []

        class FakeVariable:
            def __init__(self):
                self.callbacks = []

            def trace_add(self, mode, callback):
                self.callbacks.append((mode, callback))
                return f"trace-{len(self.callbacks)}"

        class FakeScheduler:
            def after(self, delay_ms, callback):
                scheduled.append((delay_ms, callback))
                return f"after-{len(scheduled)}"

            def after_cancel(self, token):
                calls.append(("cancel", token))

        variables = [FakeVariable(), FakeVariable()]
        binder = waveform_gui.AutoSaveBinder(
            scheduler=FakeScheduler(),
            variables=variables,
            callback=lambda: calls.append("save"),
            delay_ms=500,
        )

        variables[0].callbacks[0][1]("var", "", "write")
        variables[1].callbacks[0][1]("var", "", "write")

        self.assertEqual(scheduled[0][0], 500)
        self.assertEqual(scheduled[1][0], 500)
        self.assertIn(("cancel", "after-1"), calls)
        scheduled[-1][1]()
        self.assertIn("save", calls)
        self.assertIsNone(binder.pending_after_id)

    def test_launch_without_display_returns_clear_message(self):
        env = os.environ.copy()
        env.pop("DISPLAY", None)

        result = subprocess.run(
            [sys.executable, str(SOFTWARE_DIR / "waveform_gui.py")],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("No graphical display is available", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
