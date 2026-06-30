import os
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOFTWARE_DIR = ROOT / "software"
sys.path.insert(0, str(SOFTWARE_DIR))

import waveform_gui  # type: ignore[import-not-found]  # noqa: E402
import host  # type: ignore[import-not-found]  # noqa: E402


class WaveformGuiTests(unittest.TestCase):
    def test_preview_titles_use_channel_names(self):
        self.assertEqual(
            waveform_gui.PREVIEW_TITLES,
            (
                f"CH1 DDR 0x{host.DDR_CH1_ADDR:X} vout00",
                f"CH2 DDR 0x{host.DDR_CH2_ADDR:X} vout02",
                f"CH3 DDR 0x{host.DDR_CH3_ADDR:X} vout10",
                f"CH4 DDR 0x{host.DDR_CH4_ADDR:X} vout12",
                f"CH5 DDR 0x{host.DDR_CH5_ADDR:X} vout20",
                f"CH6 DDR 0x{host.DDR_CH6_ADDR:X} vout22",
                f"CH7 DDR 0x{host.DDR_CH7_ADDR:X} vout30",
                f"CH8 DDR 0x{host.DDR_CH8_ADDR:X} vout32",
            ),
        )
        self.assertEqual(waveform_gui.CHANNELS, ("ch1", "ch2", "ch3", "ch4", "ch5", "ch6", "ch7", "ch8"))
        self.assertEqual(len(waveform_gui.PREVIEW_COLORS), 8)

    def test_waveform_types_expose_pypulse_iq_mode(self):
        self.assertEqual(waveform_gui.WAVEFORM_TYPES, ("iq-sine", "dc-iq-cw", "pypulse", "quantum", "sine"))
        self.assertEqual(waveform_gui.DEFAULT_CHANNEL_WAVEFORM_TYPE, "iq-sine")
        self.assertEqual(waveform_gui.PYPULSE_WAVEFORMS, ("xy", "z", "readout"))
        self.assertEqual(waveform_gui.CHANNEL_FIELD_GROUPS["iq-sine"], ("freq_hz", "phase_rad", "amplitude"))
        self.assertEqual(waveform_gui.CHANNEL_FIELD_GROUPS["pypulse"], ("pypulse_waveform", "freq_hz", "phase_rad", "duration_s", "amplitude"))
        self.assertEqual(waveform_gui.CHANNEL_FIELD_GROUPS["quantum"], ("quantum_gate", "rotation_angle_rad", "freq_hz", "phase_rad", "delay_s", "duration_s", "amplitude"))
        self.assertEqual(waveform_gui.CHANNEL_FIELD_GROUPS["sine"], ("freq_hz", "phase_rad", "amplitude", "encoding"))

    def test_gui_waveform_type_falls_back_for_legacy_modes(self):
        self.assertEqual(waveform_gui._gui_waveform_type("pypulse"), "pypulse")
        self.assertEqual(waveform_gui._gui_waveform_type("per-channel"), "iq-sine")
        self.assertEqual(waveform_gui._gui_waveform_type("golden"), "iq-sine")
        self.assertEqual(waveform_gui._gui_waveform_type(None), "iq-sine")

    def test_engineering_unit_labels_hide_scientific_notation(self):
        self.assertEqual(waveform_gui.LABELS["quantum_gate"], "Quantum gate (X=I, Y=Q+90deg, Z=paired phase)")
        self.assertEqual(waveform_gui.LABELS["freq_hz"], "Scope target freq (MHz)")
        self.assertEqual(waveform_gui.LABELS["delay_s"], "Hardware delay (ns)")
        self.assertEqual(waveform_gui.LABELS["duration_s"], "Burst duration (ns)")
        self.assertEqual(waveform_gui.LABELS["pypulse_waveform"], "PyPulse waveform")
        self.assertEqual(waveform_gui.GLOBAL_SAMPLE_RATE_LABEL, "Python sample rate (GS/s)")
        self.assertEqual(waveform_gui.GLOBAL_RFDC_INTERPOLATION_LABEL, "RFDC interpolation (x)")

    def test_engineering_unit_conversions(self):
        self.assertEqual(waveform_gui.to_display_mhz(100e6), "100")
        self.assertEqual(waveform_gui.to_display_ns(120e-9), "120")
        self.assertEqual(waveform_gui.to_display_gsps(1.0e9), "1")
        self.assertEqual(waveform_gui.from_display_mhz("100"), 100e6)
        self.assertEqual(waveform_gui.from_display_ns("120"), 120e-9)
        self.assertEqual(waveform_gui.from_display_gsps("1"), 1.0e9)

    def test_left_controls_define_tabbed_container(self):
        self.assertEqual(waveform_gui.CONTROL_TABS, ("Setup", "Channels", "ILA Report"))
        self.assertEqual(
            waveform_gui.CONTROL_TAB_MARKERS,
            ("ttk.Notebook", "Setup", "Channels", "ILA Report"),
        )

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

    def test_long_semantic_labels_have_short_display_copy(self):
        self.assertEqual(waveform_gui.LABELS["quantum_gate"], "Quantum gate (X=I, Y=Q+90deg, Z=paired phase)")
        self.assertEqual(waveform_gui.FIELD_DISPLAY_LABELS["quantum_gate"], "Quantum gate")
        self.assertIn("Q+90deg", waveform_gui.FIELD_HELP_TEXTS["quantum_gate"])


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
