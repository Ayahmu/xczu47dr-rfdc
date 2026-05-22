import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SOFTWARE_DIR = ROOT / "software"
sys.path.insert(0, str(SOFTWARE_DIR))

import host  # type: ignore[import-not-found]  # noqa: E402
import waveform_tools  # type: ignore[import-not-found]  # noqa: E402
import waveform_gui_model  # type: ignore[import-not-found]  # noqa: E402


class WaveformGuiModelTests(unittest.TestCase):
    def test_connection_defaults_match_10g_bringup_link(self):
        connection = waveform_gui_model.ConnectionConfig()

        self.assertEqual(connection.ip, host.DEFAULT_BOARD_IP)
        self.assertEqual(connection.port, host.DEFAULT_BOARD_PORT)
        self.assertEqual(connection.udp_interface, "enp225s0f0")
        self.assertEqual(connection.udp_source_ip, "192.168.1.10")

    def test_sine_config_generates_distinct_xy_waveforms_and_metadata(self):
        config = waveform_gui_model.WaveformConfig(
            mode="sine",
            x_freq_hz=20e6,
            y_freq_hz=80e6,
            x_phase_rad=0.0,
            y_phase_rad=1.57079632679,
            amplitude=12000,
            sample_rate_hz=host.DAC_XY_FS,
            loop=True,
            encoding="signed",
        )

        result = waveform_gui_model.generate_waveforms(config)

        self.assertEqual(result.x.dtype, np.int16)
        self.assertEqual(result.y.dtype, np.int16)
        self.assertEqual(len(result.x), host.NUM_SAMPLES)
        self.assertEqual(len(result.y), host.NUM_SAMPLES)
        self.assertFalse(np.array_equal(result.x, result.y))
        self.assertEqual(result.metadata["mode"], "sine")
        self.assertEqual(result.metadata["x_freq_hz"], 20e6)
        self.assertEqual(result.metadata["y_freq_hz"], 80e6)
        self.assertTrue(result.metadata["loop"])

    def test_burst_config_preserves_timing_parameters_in_metadata(self):
        config = waveform_gui_model.WaveformConfig(
            mode="burst",
            x_freq_hz=80e6,
            y_freq_hz=120e6,
            x_delay_s=80e-9,
            y_delay_s=140e-9,
            duration_s=120e-9,
            amplitude=24000,
            sample_rate_hz=host.DAC_XY_FS,
        )

        result = waveform_gui_model.generate_waveforms(config)

        self.assertGreater(np.max(np.abs(result.x)), 1000)
        self.assertGreater(np.max(np.abs(result.y)), 1000)
        self.assertEqual(result.metadata["mode"], "burst")
        self.assertEqual(result.metadata["x_delay_s"], 80e-9)
        self.assertEqual(result.metadata["y_delay_s"], 140e-9)
        self.assertEqual(result.metadata["duration_s"], 120e-9)

    def test_golden_config_generates_incrementing_debug_pattern(self):
        config = waveform_gui_model.WaveformConfig(mode="golden", x_start=0, y_start=0x1000)

        result = waveform_gui_model.generate_waveforms(config)

        np.testing.assert_array_equal(result.x[:8], np.arange(8, dtype=np.int16))
        self.assertEqual(result.y[:4].view(np.uint16).tolist(), [0x1000, 0x1001, 0x1002, 0x1003])
        self.assertEqual(result.metadata["encoding"], "uint16-viewed-as-int16")

    def test_pulse_presets_generate_channel_waveforms_and_metadata(self):
        for preset in ("x", "y", "z"):
            with self.subTest(preset=preset):
                config = waveform_gui_model.WaveformConfig(mode="pulse", pulse_preset=preset, amplitude=18000)

                result = waveform_gui_model.generate_waveforms(config)

                self.assertEqual(result.x.dtype, np.int16)
                self.assertEqual(result.y.dtype, np.int16)
                peak_sum = int(np.max(np.abs(result.x))) + int(np.max(np.abs(result.y)))
                self.assertGreater(peak_sum, 1000)
                self.assertEqual(result.metadata["mode"], "pulse")
                self.assertEqual(result.metadata["pulse_preset"], preset)
                self.assertEqual(result.metadata["ch1_label"], "CH1 / DDR X")
                self.assertEqual(result.metadata["ch2_label"], "CH2 / DDR Y")

        x_pulse = waveform_gui_model.generate_waveforms(waveform_gui_model.WaveformConfig(mode="pulse", pulse_preset="x"))
        y_pulse = waveform_gui_model.generate_waveforms(waveform_gui_model.WaveformConfig(mode="pulse", pulse_preset="y"))
        z_pulse = waveform_gui_model.generate_waveforms(waveform_gui_model.WaveformConfig(mode="pulse", pulse_preset="z"))

        self.assertGreater(np.max(np.abs(x_pulse.x)), np.max(np.abs(x_pulse.y)))
        self.assertGreater(np.max(np.abs(y_pulse.y)), np.max(np.abs(y_pulse.x)))
        np.testing.assert_array_equal(z_pulse.x, -z_pulse.y)

    def test_independent_channel_generation_allows_different_types_and_off(self):
        config = waveform_gui_model.WaveformConfig(
            sample_rate_hz=host.DAC_XY_FS,
            ch1=waveform_gui_model.ChannelWaveformConfig(
                waveform_type="sine",
                freq_hz=20e6,
                phase_rad=0.0,
                amplitude=9000,
                encoding="signed",
            ),
            ch2=waveform_gui_model.ChannelWaveformConfig(waveform_type="off"),
        )

        result = waveform_gui_model.generate_waveforms(config)

        self.assertEqual(result.x.dtype, np.int16)
        self.assertEqual(result.y.dtype, np.int16)
        self.assertEqual(len(result.x), host.NUM_SAMPLES)
        self.assertEqual(len(result.y), host.NUM_SAMPLES)
        self.assertGreater(np.max(np.abs(result.x)), 1000)
        self.assertFalse(np.any(result.y))
        self.assertEqual(result.metadata["mode"], "per-channel")
        self.assertEqual(result.metadata["ch1"]["type"], "sine")
        self.assertEqual(result.metadata["ch2"]["type"], "off")

    def test_independent_channels_preserve_ddr_x_y_upload_mapping(self):
        config = waveform_gui_model.WaveformConfig(
            ch1=waveform_gui_model.ChannelWaveformConfig(waveform_type="golden", start=0x20),
            ch2=waveform_gui_model.ChannelWaveformConfig(
                waveform_type="pulse",
                pulse_preset="z",
                pulse_sigma_s=20e-9,
                pulse_center_s=80e-9,
                amplitude=15000,
            ),
        )

        result = waveform_gui_model.generate_waveforms(config)

        self.assertEqual(result.x[:4].view(np.uint16).tolist(), [0x20, 0x21, 0x22, 0x23])
        self.assertLess(int(np.min(result.y)), -1000)
        self.assertEqual(result.metadata["ch1_label"], "CH1 / DDR X")
        self.assertEqual(result.metadata["ch2_label"], "CH2 / DDR Y")
        self.assertEqual(result.metadata["ch1"]["upload_arg"], "x")
        self.assertEqual(result.metadata["ch2"]["upload_arg"], "y")

    def test_quantum_x_gate_drives_i_quadrature_only(self):
        config = waveform_gui_model.WaveformConfig(
            sample_rate_hz=host.DAC_XY_FS,
            ch1=waveform_gui_model.ChannelWaveformConfig(waveform_type="quantum", quantum_gate="x", freq_hz=80e6, phase_rad=0.0, amplitude=24000, duration_s=120e-9, delay_s=80e-9),
            ch2=waveform_gui_model.ChannelWaveformConfig(waveform_type="off"),
        )
        expected = waveform_tools.make_gaussian_burst(80e6, 0.0, 24000, host.DAC_XY_FS, 120e-9, 80e-9)

        result = waveform_gui_model.generate_waveforms(config)

        np.testing.assert_array_equal(result.x, expected)
        self.assertGreater(int(np.max(np.abs(result.x))), 1000)
        self.assertFalse(np.any(result.y))
        self.assertEqual(result.metadata["ch1"]["type"], "quantum")
        self.assertEqual(result.metadata["ch1"]["quantum_gate"], "x")
        self.assertEqual(result.metadata["ch1"]["semantics"], "X rotation drive on I quadrature")

    def test_quantum_y_gate_drives_q_quadrature_only(self):
        config = waveform_gui_model.WaveformConfig(
            sample_rate_hz=host.DAC_XY_FS,
            ch1=waveform_gui_model.ChannelWaveformConfig(waveform_type="off"),
            ch2=waveform_gui_model.ChannelWaveformConfig(waveform_type="quantum", quantum_gate="y", freq_hz=120e6, phase_rad=0.0, amplitude=24000, duration_s=120e-9, delay_s=120e-9),
        )
        expected = waveform_tools.make_gaussian_burst(120e6, np.pi / 2.0, 24000, host.DAC_XY_FS, 120e-9, 120e-9)

        result = waveform_gui_model.generate_waveforms(config)

        self.assertFalse(np.any(result.x))
        np.testing.assert_array_equal(result.y, expected)
        self.assertGreater(int(np.max(np.abs(result.y))), 1000)
        self.assertEqual(result.metadata["ch2"]["quantum_gate"], "y")
        self.assertEqual(result.metadata["ch2"]["semantics"], "Y rotation drive with +90 degree quadrature phase")
        self.assertEqual(result.metadata["ch2"]["pulse_backend"], "scipy")

    def test_pulse_x_y_presets_match_send_xy_gaussian_bursts(self):
        config = waveform_gui_model.WaveformConfig(
            sample_rate_hz=host.DAC_XY_FS,
            ch1=waveform_gui_model.ChannelWaveformConfig(waveform_type="pulse", pulse_preset="x", freq_hz=80e6, phase_rad=0.0, amplitude=24000, duration_s=120e-9, delay_s=80e-9),
            ch2=waveform_gui_model.ChannelWaveformConfig(waveform_type="pulse", pulse_preset="y", freq_hz=120e6, phase_rad=0.0, amplitude=24000, duration_s=120e-9, delay_s=120e-9),
        )
        expected_x = waveform_tools.make_gaussian_burst(80e6, 0.0, 24000, host.DAC_XY_FS, 120e-9, 80e-9)
        expected_y = waveform_tools.make_gaussian_burst(120e6, 0.0, 24000, host.DAC_XY_FS, 120e-9, 120e-9)

        result = waveform_gui_model.generate_waveforms(config)

        np.testing.assert_array_equal(result.x, expected_x)
        np.testing.assert_array_equal(result.y, expected_y)

    def test_quantum_z_gate_emits_scipy_phase_marker_pulse(self):
        config = waveform_gui_model.WaveformConfig(
            sample_rate_hz=host.DAC_XY_FS,
            ch1=waveform_gui_model.ChannelWaveformConfig(
                waveform_type="quantum",
                quantum_gate="z",
                virtual_z_phase_rad=1.57079632679,
                amplitude=12000,
                duration_s=120e-9,
                delay_s=80e-9,
            ),
            ch2=waveform_gui_model.ChannelWaveformConfig(
                waveform_type="quantum",
                quantum_gate="z",
                virtual_z_phase_rad=1.57079632679,
                amplitude=12000,
                duration_s=120e-9,
                delay_s=80e-9,
            ),
        )

        result = waveform_gui_model.generate_waveforms(config)

        self.assertGreater(int(np.max(result.x)), 1000)
        self.assertLess(int(np.min(result.y)), -1000)
        np.testing.assert_array_equal(result.y, (-result.x).astype(np.int16))
        self.assertEqual(result.metadata["ch1"]["quantum_gate"], "z")
        self.assertEqual(result.metadata["ch1"]["semantics"], "Z detuning-style phase pulse on DAC pair")
        self.assertEqual(result.metadata["ch1"]["pulse_backend"], "scipy")
        self.assertAlmostEqual(result.metadata["ch1"]["virtual_z_phase_rad"], 1.57079632679)

    def test_dry_run_saves_artifacts_without_uploading(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config = waveform_gui_model.WaveformConfig(mode="sine", output_dir=Path(temp_dir), dry_run=True)
            connection = waveform_gui_model.ConnectionConfig(ip="192.0.2.10", port=1234)
            controller = waveform_gui_model.WaveformController(uploader=mock.Mock())

            result = controller.run(config, connection)

            self.assertTrue(result.dry_run)
            self.assertIn("dry-run", "\n".join(result.log_lines))
            self.assertTrue((Path(temp_dir) / "x_waveform.npy").exists())
            self.assertTrue((Path(temp_dir) / "sine_metadata.json").exists())
            controller.uploader.assert_not_called()

    def test_send_uses_upload_helper_with_connection_settings(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config = waveform_gui_model.WaveformConfig(
                mode="golden",
                output_dir=Path(temp_dir),
                dry_run=False,
                loop=True,
                wait_for_trigger=True,
            )
            connection = waveform_gui_model.ConnectionConfig(
                ip="192.0.2.20",
                port=4567,
                udp_interface="eth-test",
                udp_source_ip="192.0.2.1",
                timeout_s=1.25,
                post_upload_sleep_s=0.05,
            )
            uploader = mock.Mock()
            controller = waveform_gui_model.WaveformController(uploader=uploader)

            result = controller.run(config, connection)

            self.assertFalse(result.dry_run)
            uploader.assert_called_once()
            _, kwargs = uploader.call_args
            self.assertEqual(kwargs["ip"], "192.0.2.20")
            self.assertEqual(kwargs["port"], 4567)
            self.assertEqual(kwargs["udp_interface"], "eth-test")
            self.assertEqual(kwargs["udp_source_ip"], "192.0.2.1")
            self.assertEqual(kwargs["timeout_s"], 1.25)
            self.assertEqual(kwargs["post_upload_sleep_s"], 0.05)
            self.assertTrue(kwargs["loop"])
            self.assertFalse(kwargs["auto_start"])

    def test_build_send_summary_includes_target_and_channel_plan(self):
        config = waveform_gui_model.WaveformConfig(
            sample_rate_hz=host.DAC_XY_FS,
            loop=True,
            wait_for_trigger=True,
            ch1=waveform_gui_model.ChannelWaveformConfig(waveform_type="quantum", quantum_gate="x"),
            ch2=waveform_gui_model.ChannelWaveformConfig(waveform_type="sine", freq_hz=40e6),
        )
        connection = waveform_gui_model.ConnectionConfig(ip="192.0.2.30", port=7890, udp_interface="eth-test", udp_source_ip="192.0.2.2")

        summary = waveform_gui_model.build_send_summary(config, connection)

        self.assertIn("Target: 192.0.2.30:7890", summary)
        self.assertIn("UDP interface: eth-test", summary)
        self.assertIn("Source IP: 192.0.2.2", summary)
        self.assertIn("Loop playback: yes", summary)
        self.assertIn("Auto start: no, wait for trigger", summary)
        self.assertIn("CH1 / DDR X: quantum x", summary)
        self.assertIn("CH2 / DDR Y: sine", summary)

    def test_connection_tester_sends_minimal_udp_probe(self):
        calls = []

        def sender(connection, payload):
            calls.append((connection, payload))
            return len(payload)

        connection = waveform_gui_model.ConnectionConfig(ip="192.0.2.40", port=9876)
        result = waveform_gui_model.test_connection(connection, sender=sender)

        self.assertTrue(result.ok)
        self.assertIn("sent", result.message)
        self.assertEqual(calls[0][0], connection)
        self.assertEqual(calls[0][1], waveform_gui_model.CONNECTION_TEST_PAYLOAD)

    def test_controller_logs_progress_stages_for_real_send(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config = waveform_gui_model.WaveformConfig(mode="golden", output_dir=Path(temp_dir), dry_run=False)
            connection = waveform_gui_model.ConnectionConfig(ip="192.0.2.50", port=1357)
            controller = waveform_gui_model.WaveformController(uploader=mock.Mock())

            result = controller.run(config, connection)

            joined = "\n".join(result.log_lines)
            self.assertIn("progress: generated waveforms", joined)
            self.assertIn("progress: saved artifacts", joined)
            self.assertIn("progress: sending UDP packets", joined)
            self.assertIn("progress: send complete", joined)

    def test_controller_logs_progress_stages_for_dry_run(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config = waveform_gui_model.WaveformConfig(mode="golden", output_dir=Path(temp_dir), dry_run=True)
            connection = waveform_gui_model.ConnectionConfig(ip="192.0.2.60", port=2468)
            controller = waveform_gui_model.WaveformController(uploader=mock.Mock())

            result = controller.run(config, connection)

            joined = "\n".join(result.log_lines)
            self.assertIn("progress: generated waveforms", joined)
            self.assertIn("progress: saved artifacts", joined)
            self.assertIn("progress: dry-run complete", joined)
            self.assertNotIn("progress: sending UDP packets", joined)


if __name__ == "__main__":
    unittest.main()
