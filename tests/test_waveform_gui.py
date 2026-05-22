import os
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOFTWARE_DIR = ROOT / "software"
sys.path.insert(0, str(SOFTWARE_DIR))

import waveform_gui  # type: ignore[import-not-found]  # noqa: E402


class WaveformGuiTests(unittest.TestCase):
    def test_preview_titles_use_channel_names(self):
        self.assertEqual(waveform_gui.PREVIEW_TITLES[0], "CH1 I-drive waveform (DDR X)")
        self.assertEqual(waveform_gui.PREVIEW_TITLES[1], "CH2 Q-drive waveform (DDR Y)")

    def test_waveform_types_include_quantum_operation(self):
        self.assertIn("quantum", waveform_gui.WAVEFORM_TYPES)
        self.assertEqual(waveform_gui.CHANNEL_FIELD_GROUPS["quantum"], ("quantum_gate", "rotation_angle_rad", "freq_hz", "phase_rad", "delay_s", "duration_s", "amplitude"))

    def test_engineering_unit_labels_hide_scientific_notation(self):
        self.assertEqual(waveform_gui.LABELS["quantum_gate"], "Quantum gate (X=I, Y=Q+90deg, Z=paired phase)")
        self.assertEqual(waveform_gui.LABELS["freq_hz"], "Frequency (MHz)")
        self.assertEqual(waveform_gui.LABELS["delay_s"], "Burst delay (ns)")
        self.assertEqual(waveform_gui.LABELS["duration_s"], "Burst duration (ns)")
        self.assertEqual(waveform_gui.GLOBAL_SAMPLE_RATE_LABEL, "Sample rate (GS/s)")

    def test_engineering_unit_conversions(self):
        self.assertEqual(waveform_gui.to_display_mhz(100e6), "100")
        self.assertEqual(waveform_gui.to_display_ns(120e-9), "120")
        self.assertEqual(waveform_gui.to_display_gsps(4.608e9), "4.608")
        self.assertEqual(waveform_gui.from_display_mhz("100"), 100e6)
        self.assertEqual(waveform_gui.from_display_ns("120"), 120e-9)
        self.assertEqual(waveform_gui.from_display_gsps("4.608"), 4.608e9)

    def test_left_controls_define_scrollable_container(self):
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
