import sys
import subprocess
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
    def test_default_sample_rate_matches_custom_rfdc_config(self):
        self.assertEqual(waveform_gui_model.WaveformConfig().sample_rate_hz, 1_200_000_000.0)

    def test_default_axis_frequency_matches_custom_rfdc_axis_clock(self):
        self.assertEqual(waveform_gui_model.WaveformConfig().axis_freq_hz, 300_000_000.0)

    def test_default_rfdc_interpolation_matches_custom_rfdc_config(self):
        self.assertEqual(waveform_gui_model.WaveformConfig().rfdc_interpolation, 2)

    def test_rfdc_interpolation_scales_scope_frequency_to_python_frequency(self):
        config = waveform_gui_model.WaveformConfig(
            sample_rate_hz=1_200_000_000.0,
            rfdc_interpolation=2,
            ch1=waveform_gui_model.ChannelWaveformConfig(waveform_type="sine", freq_hz=200_000_000.0),
        )

        result = waveform_gui_model.generate_waveforms(config)

        self.assertEqual(result.metadata["sample_rate_hz"], 1_200_000_000.0)
        self.assertEqual(result.metadata["rfdc_interpolation"], 2)
        self.assertEqual(result.metadata["analog_sample_rate_hz"], 2_400_000_000.0)
        self.assertEqual(result.metadata["ch1"]["scope_freq_hz"], 200_000_000.0)
        self.assertEqual(result.metadata["ch1"]["python_freq_hz"], 400_000_000.0)

    def test_generated_waveforms_are_channel_primary_with_xy_aliases(self):
        fields = set(waveform_gui_model.GeneratedWaveforms.__dataclass_fields__)

        self.assertIn("ch1", fields)
        self.assertIn("ch2", fields)
        self.assertNotIn("x", fields)
        self.assertNotIn("y", fields)

    def test_connection_defaults_match_10g_bringup_link(self):
        connection = waveform_gui_model.ConnectionConfig()

        self.assertEqual(connection.ip, host.DEFAULT_BOARD_IP)
        self.assertEqual(connection.port, host.DEFAULT_BOARD_PORT)
        self.assertEqual(connection.udp_interface, "enp225s0f0")
        self.assertEqual(connection.udp_source_ip, "192.168.1.10")

    def test_local_gui_settings_round_trip_json(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            settings_path = Path(temp_dir) / "waveform_gui_settings.json"
            settings = waveform_gui_model.GuiSettings(
                waveform=waveform_gui_model.WaveformConfig(
                    mode="per-channel",
                    output_dir=Path("/tmp/custom-waveforms"),
                    sample_rate_hz=1_200_000_000.0,
                    loop=True,
                    wait_for_trigger=True,
                    dry_run=False,
                    ch1=waveform_gui_model.ChannelWaveformConfig(waveform_type="quantum", quantum_gate="x", freq_hz=80e6, delay_s=12e-9),
                    ch2=waveform_gui_model.ChannelWaveformConfig(waveform_type="sine", freq_hz=120e6, phase_rad=0.25),
                    ch3=waveform_gui_model.ChannelWaveformConfig(waveform_type="quantum", quantum_gate="y", amplitude=21000),
                    ch4=waveform_gui_model.ChannelWaveformConfig(waveform_type="sine", encoding="offset-binary"),
                ),
                connection=waveform_gui_model.ConnectionConfig(
                    ip="192.0.2.44",
                    port=4321,
                    udp_interface="eth-local",
                    udp_source_ip="192.0.2.1",
                    timeout_s=2.5,
                    post_upload_sleep_s=0.2,
                ),
                ila=waveform_gui_model.IlaReportConfig(
                    bitstream_path=Path("build/custom.bit"),
                    ltx_path=Path("build/custom.ltx"),
                    output_dir=Path("reports/ila"),
                    artifact_dir=Path("/tmp/custom-waveforms"),
                    program_mode="auto",
                ),
            )

            waveform_gui_model.save_gui_settings(settings, settings_path)
            loaded = waveform_gui_model.load_gui_settings(settings_path)

            self.assertEqual(loaded.connection.ip, "192.0.2.44")
            self.assertEqual(loaded.connection.port, 4321)
            self.assertEqual(loaded.connection.udp_interface, "eth-local")
            self.assertEqual(loaded.waveform.output_dir, Path("/tmp/custom-waveforms"))
            self.assertTrue(loaded.waveform.loop)
            self.assertFalse(loaded.waveform.dry_run)
            self.assertEqual(loaded.waveform.ch1.waveform_type, "quantum")
            self.assertEqual(loaded.waveform.ch1.quantum_gate, "x")
            self.assertEqual(loaded.waveform.ch2.waveform_type, "sine")
            self.assertEqual(loaded.waveform.ch3.quantum_gate, "y")
            self.assertEqual(loaded.waveform.ch4.encoding, "offset-binary")
            self.assertEqual(loaded.ila.bitstream_path, Path("build/custom.bit"))
            self.assertEqual(loaded.ila.program_mode, "auto")

    def test_missing_local_gui_settings_use_defaults(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            settings = waveform_gui_model.load_gui_settings(Path(temp_dir) / "missing.json")

        self.assertEqual(settings.connection.ip, host.DEFAULT_BOARD_IP)
        self.assertEqual(settings.waveform.sample_rate_hz, host.DAC_XY_FS)
        self.assertEqual(settings.ila.program_mode, "never")

    def test_ila_capture_command_uses_current_python_connection_and_artifacts(self):
        connection = waveform_gui_model.ConnectionConfig(
            ip="192.168.1.55",
            port=4096,
            udp_interface="eno1",
            udp_source_ip="192.168.1.10",
            timeout_s=9.0,
            post_upload_sleep_s=0.25,
        )
        config = waveform_gui_model.IlaReportConfig(
            artifact_dir=Path("/tmp/gui-artifacts"),
            bitstream_path=Path("hardware/vivado/output/custom.bit"),
            ltx_path=Path("hardware/vivado/output/custom.ltx"),
            output_dir=Path("/tmp/ila-reports"),
            program_mode="auto",
        )

        command = waveform_gui_model.build_ila_capture_command(config, connection)

        self.assertEqual(command[0], sys.executable)
        self.assertEqual(command[1], str(SOFTWARE_DIR / "ila_capture_report.py"))
        self.assertIn("--capture", command)
        self.assertIn("--send-after-arm", command)
        self.assertEqual(command[command.index("--artifact-dir") + 1], "/tmp/gui-artifacts")
        self.assertEqual(command[command.index("--bit") + 1], "hardware/vivado/output/custom.bit")
        self.assertEqual(command[command.index("--ltx") + 1], "hardware/vivado/output/custom.ltx")
        self.assertEqual(command[command.index("--out-dir") + 1], "/tmp/ila-reports")
        self.assertEqual(command[command.index("--udp-interface") + 1], "eno1")
        self.assertEqual(command[command.index("--udp-source-ip") + 1], "192.168.1.10")
        self.assertEqual(command[command.index("--ip") + 1], "192.168.1.55")
        self.assertEqual(command[command.index("--port") + 1], "4096")
        self.assertEqual(command[command.index("--timeout-s") + 1], "9")
        self.assertEqual(command[command.index("--post-upload-sleep-s") + 1], "0.25")
        self.assertEqual(command[command.index("--program-mode") + 1], "auto")
        self.assertIn("--yes", command)

    def test_ila_capture_command_never_program_mode_omits_yes(self):
        connection = waveform_gui_model.ConnectionConfig()
        config = waveform_gui_model.IlaReportConfig(
            artifact_dir=Path("/tmp/gui-artifacts"),
            bitstream_path=Path("hardware/vivado/output/custom.bit"),
            ltx_path=Path("hardware/vivado/output/custom.ltx"),
            output_dir=Path("/tmp/ila-reports"),
            program_mode="never",
        )

        command = waveform_gui_model.build_ila_capture_command(config, connection)

        self.assertEqual(command[command.index("--program-mode") + 1], "never")
        self.assertNotIn("--yes", command)

    def test_ila_capture_report_wrapper_returns_report_paths_and_status(self):
        completed = mock.Mock(
            returncode=2,
            stdout="overall_status=FAIL\nmarkdown_report=/tmp/ila/ila_capture_report.md\njson_report=/tmp/ila/ila_capture_report.json\n",
            stderr="vivado warning\n",
        )
        runner = mock.Mock(return_value=completed)
        connection = waveform_gui_model.ConnectionConfig(ip="192.168.1.55", port=4096)
        config = waveform_gui_model.IlaReportConfig(
            artifact_dir=Path("/tmp/gui-artifacts"),
            bitstream_path=Path("hardware/vivado/output/custom.bit"),
            ltx_path=Path("hardware/vivado/output/custom.ltx"),
            output_dir=Path("/tmp/ila"),
            program_mode="never",
        )

        result = waveform_gui_model.run_ila_capture_report(config, connection, runner=runner)

        self.assertFalse(result.ok)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.overall_status, "FAIL")
        self.assertEqual(result.markdown_report, Path("/tmp/ila/ila_capture_report.md"))
        self.assertEqual(result.json_report, Path("/tmp/ila/ila_capture_report.json"))
        self.assertTrue(any("overall_status=FAIL" in line for line in result.log_lines))
        self.assertTrue(any("stderr: vivado warning" in line for line in result.log_lines))
        runner.assert_called_once()

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
        self.assertEqual(result.metadata["ch1_freq_hz"], 20e6)
        self.assertEqual(result.metadata["ch2_freq_hz"], 80e6)
        self.assertNotIn("x_freq_hz", result.metadata)
        self.assertNotIn("y_freq_hz", result.metadata)
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
            axis_freq_hz=250_000_000.0,
        )

        result = waveform_gui_model.generate_waveforms(config)

        self.assertGreater(np.max(np.abs(result.x)), 1000)
        self.assertGreater(np.max(np.abs(result.y)), 1000)
        self.assertEqual(result.metadata["mode"], "burst")
        self.assertEqual(result.metadata["ch1_delay_s"], 80e-9)
        self.assertEqual(result.metadata["ch2_delay_s"], 140e-9)
        self.assertEqual(result.metadata["axis_freq_hz"], 250_000_000.0)
        self.assertEqual(result.metadata["ch1_delay_cycles"], 20)
        self.assertEqual(result.metadata["ch2_delay_cycles"], 35)
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
                self.assertEqual(result.metadata["ch1_label"], "CH1 / DDR 0x0 / DAC20")
                self.assertEqual(result.metadata["ch2_label"], "CH2 / DDR 0x1000 / DAC22")

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
            ch3=waveform_gui_model.ChannelWaveformConfig(waveform_type="golden", start=0x2000),
            ch4=waveform_gui_model.ChannelWaveformConfig(
                waveform_type="sine",
                freq_hz=60e6,
                phase_rad=0.5,
                amplitude=7000,
                encoding="signed",
            ),
        )

        result = waveform_gui_model.generate_waveforms(config)

        self.assertEqual(result.x.dtype, np.int16)
        self.assertEqual(result.y.dtype, np.int16)
        self.assertEqual(result.ch3.dtype, np.int16)
        self.assertEqual(result.ch4.dtype, np.int16)
        self.assertEqual(len(result.x), host.NUM_SAMPLES)
        self.assertEqual(len(result.y), host.NUM_SAMPLES)
        self.assertEqual(len(result.ch3), host.NUM_SAMPLES)
        self.assertEqual(len(result.ch4), host.NUM_SAMPLES)
        self.assertGreater(np.max(np.abs(result.x)), 1000)
        self.assertFalse(np.any(result.y))
        self.assertEqual(result.ch3[:4].view(np.uint16).tolist(), [0x2000, 0x2001, 0x2002, 0x2003])
        self.assertGreater(np.max(np.abs(result.ch4)), 1000)
        self.assertEqual(result.metadata["mode"], "per-channel")
        self.assertEqual(result.metadata["ch1"]["type"], "sine")
        self.assertEqual(result.metadata["ch2"]["type"], "off")
        self.assertEqual(result.metadata["ch3"]["type"], "golden")
        self.assertEqual(result.metadata["ch4"]["type"], "sine")
        self.assertEqual(result.metadata["ch3"]["upload_arg"], "ch3")
        self.assertEqual(result.metadata["ch4"]["upload_arg"], "ch4")

    def test_channel_delay_cycles_use_axis_frequency_not_waveform_samples(self):
        config = waveform_gui_model.WaveformConfig(
            sample_rate_hz=1_200_000_000.0,
            axis_freq_hz=250_000_000.0,
            ch1=waveform_gui_model.ChannelWaveformConfig(waveform_type="quantum", delay_s=80e-9),
            ch2=waveform_gui_model.ChannelWaveformConfig(waveform_type="quantum", delay_s=120e-9),
        )

        self.assertEqual(waveform_gui_model.channel_delay_cycles(config), {1: 20, 2: 30})

        result = waveform_gui_model.generate_waveforms(config)

        self.assertEqual(result.metadata["ch1"]["delay_cycles"], 20)
        self.assertEqual(result.metadata["ch2"]["delay_cycles"], 30)

    def test_quantum_z_delay_is_hardware_only_not_waveform_padding(self):
        no_delay = waveform_gui_model.WaveformConfig(
            axis_freq_hz=300_000_000.0,
            ch1=waveform_gui_model.ChannelWaveformConfig(waveform_type="quantum", quantum_gate="z", delay_s=0.0),
        )
        delayed = waveform_gui_model.WaveformConfig(
            axis_freq_hz=300_000_000.0,
            ch1=waveform_gui_model.ChannelWaveformConfig(waveform_type="quantum", quantum_gate="z", delay_s=80e-9),
        )

        np.testing.assert_array_equal(
            waveform_gui_model.generate_waveforms(no_delay).ch1,
            waveform_gui_model.generate_waveforms(delayed).ch1,
        )
        self.assertEqual(waveform_gui_model.channel_delay_cycles(delayed), {1: 24})

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
        self.assertEqual(result.metadata["ch1_label"], "CH1 / DDR 0x0 / DAC20")
        self.assertEqual(result.metadata["ch2_label"], "CH2 / DDR 0x1000 / DAC22")
        self.assertEqual(result.metadata["ch1"]["upload_arg"], "x")
        self.assertEqual(result.metadata["ch2"]["upload_arg"], "y")

    def test_quantum_x_gate_is_per_channel(self):
        config = waveform_gui_model.WaveformConfig(
            sample_rate_hz=host.DAC_XY_FS,
            ch1=waveform_gui_model.ChannelWaveformConfig(waveform_type="quantum", quantum_gate="x", freq_hz=80e6, phase_rad=0.0, amplitude=24000, duration_s=120e-9, delay_s=80e-9),
            ch2=waveform_gui_model.ChannelWaveformConfig(waveform_type="quantum", quantum_gate="x", freq_hz=80e6, phase_rad=0.0, amplitude=24000, duration_s=120e-9, delay_s=80e-9),
        )
        expected = waveform_tools.make_gaussian_burst(160e6, 0.0, 24000, host.DAC_XY_FS, 120e-9, 80e-9)

        result = waveform_gui_model.generate_waveforms(config)

        np.testing.assert_array_equal(result.x, expected)
        np.testing.assert_array_equal(result.y, expected)
        self.assertGreater(int(np.max(np.abs(result.x))), 1000)
        self.assertGreater(int(np.max(np.abs(result.y))), 1000)
        self.assertEqual(result.metadata["ch1"]["type"], "quantum")
        self.assertEqual(result.metadata["ch1"]["quantum_gate"], "x")
        self.assertEqual(result.metadata["ch1"]["semantics"], "X rotation drive on this DAC channel")
        self.assertEqual(result.metadata["ch2"]["semantics"], "X rotation drive on this DAC channel")

    def test_quantum_y_gate_is_per_channel_quadrature_phase(self):
        config = waveform_gui_model.WaveformConfig(
            sample_rate_hz=host.DAC_XY_FS,
            ch1=waveform_gui_model.ChannelWaveformConfig(waveform_type="quantum", quantum_gate="y", freq_hz=120e6, phase_rad=0.0, amplitude=24000, duration_s=120e-9, delay_s=120e-9),
            ch2=waveform_gui_model.ChannelWaveformConfig(waveform_type="quantum", quantum_gate="y", freq_hz=120e6, phase_rad=0.0, amplitude=24000, duration_s=120e-9, delay_s=120e-9),
        )
        expected = waveform_tools.make_gaussian_burst(240e6, np.pi / 2.0, 24000, host.DAC_XY_FS, 120e-9, 120e-9)

        result = waveform_gui_model.generate_waveforms(config)

        np.testing.assert_array_equal(result.x, expected)
        np.testing.assert_array_equal(result.y, expected)
        self.assertGreater(int(np.max(np.abs(result.x))), 1000)
        self.assertGreater(int(np.max(np.abs(result.y))), 1000)
        self.assertEqual(result.metadata["ch1"]["quantum_gate"], "y")
        self.assertEqual(result.metadata["ch2"]["quantum_gate"], "y")
        self.assertEqual(result.metadata["ch1"]["semantics"], "Y rotation drive with +90 degree phase on this DAC channel")
        self.assertEqual(result.metadata["ch2"]["semantics"], "Y rotation drive with +90 degree phase on this DAC channel")
        self.assertEqual(result.metadata["ch2"]["pulse_backend"], "scipy")

    def test_pulse_x_y_presets_match_send_xy_gaussian_bursts(self):
        config = waveform_gui_model.WaveformConfig(
            sample_rate_hz=host.DAC_XY_FS,
            ch1=waveform_gui_model.ChannelWaveformConfig(waveform_type="pulse", pulse_preset="x", freq_hz=80e6, phase_rad=0.0, amplitude=24000, duration_s=120e-9, delay_s=80e-9),
            ch2=waveform_gui_model.ChannelWaveformConfig(waveform_type="pulse", pulse_preset="y", freq_hz=120e6, phase_rad=0.0, amplitude=24000, duration_s=120e-9, delay_s=120e-9),
        )
        expected_x = waveform_tools.make_gaussian_burst(160e6, 0.0, 24000, host.DAC_XY_FS, 120e-9, 80e-9)
        expected_y = waveform_tools.make_gaussian_burst(240e6, 0.0, 24000, host.DAC_XY_FS, 120e-9, 120e-9)

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

    def test_burst_delay_controls_idle_cycles_not_waveform_prefix(self):
        config = waveform_gui_model.WaveformConfig(
            mode="per-channel",
            sample_rate_hz=host.DAC_XY_FS,
            ch1=waveform_gui_model.ChannelWaveformConfig(
                waveform_type="burst",
                freq_hz=80e6,
                delay_s=0.0,
                duration_s=120e-9,
                amplitude=20000,
            ),
            ch2=waveform_gui_model.ChannelWaveformConfig(
                waveform_type="burst",
                freq_hz=80e6,
                delay_s=80e-9,
                duration_s=120e-9,
                amplitude=20000,
            ),
        )

        result = waveform_gui_model.generate_waveforms(config)

        np.testing.assert_array_equal(result.ch1, result.ch2)
        self.assertEqual(result.metadata["ch1"]["delay_cycles"], 0)
        self.assertEqual(result.metadata["ch2"]["delay_cycles"], 24)

    def test_dry_run_saves_artifacts_without_uploading(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config = waveform_gui_model.WaveformConfig(mode="sine", output_dir=Path(temp_dir), dry_run=True)
            connection = waveform_gui_model.ConnectionConfig(ip="192.0.2.10", port=1234)
            controller = waveform_gui_model.WaveformController(uploader=mock.Mock())

            result = controller.run(config, connection)

            self.assertTrue(result.dry_run)
            self.assertIn("dry-run", "\n".join(result.log_lines))
            self.assertTrue((Path(temp_dir) / "x_waveform.npy").exists())
            self.assertTrue((Path(temp_dir) / "ch1_waveform.npy").exists())
            self.assertTrue((Path(temp_dir) / "ch2_waveform.npy").exists())
            self.assertTrue((Path(temp_dir) / "ch3_waveform.npy").exists())
            self.assertTrue((Path(temp_dir) / "ch4_waveform.npy").exists())
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
            self.assertIn("ch3", kwargs)
            self.assertIn("ch4", kwargs)
            self.assertEqual(kwargs["ch3"].dtype, np.int16)
            self.assertEqual(kwargs["ch4"].dtype, np.int16)

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
        self.assertIn("CH1 / DDR 0x0 / DAC20: quantum x", summary)
        self.assertIn("CH2 / DDR 0x1000 / DAC22: sine", summary)
        self.assertIn("CH3 / DDR 0x2000 / DAC30: off", summary)
        self.assertIn("CH4 / DDR 0x3000 / DAC32: off", summary)

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

    def test_ila_report_command_uses_connection_and_capture_settings(self):
        config = waveform_gui_model.IlaReportConfig(
            bit_path=Path("hardware/vivado/output/test.bit"),
            ltx_path=Path("hardware/vivado/output/test.ltx"),
            report_dir=Path("software/ila_reports"),
            artifact_dir=Path("software/waveform_out"),
            program_fpga=True,
        )
        connection = waveform_gui_model.ConnectionConfig(
            ip="192.0.2.70",
            port=4321,
            udp_interface="eth-ila",
            udp_source_ip="192.0.2.9",
            timeout_s=7.5,
        )

        command = waveform_gui_model.build_ila_report_command(config, connection)

        self.assertEqual(command[0], sys.executable)
        self.assertIn(str(SOFTWARE_DIR / "ila_capture_report.py"), command)
        self.assertIn("--capture", command)
        self.assertIn("--send-after-arm", command)
        self.assertIn("--artifact-dir", command)
        self.assertEqual(command[command.index("--artifact-dir") + 1], "software/waveform_out")
        self.assertEqual(command[command.index("--bit") + 1], "hardware/vivado/output/test.bit")
        self.assertEqual(command[command.index("--ltx") + 1], "hardware/vivado/output/test.ltx")
        self.assertEqual(command[command.index("--out-dir") + 1], "software/ila_reports")
        self.assertEqual(command[command.index("--udp-interface") + 1], "eth-ila")
        self.assertEqual(command[command.index("--udp-source-ip") + 1], "192.0.2.9")
        self.assertEqual(command[command.index("--ip") + 1], "192.0.2.70")
        self.assertEqual(command[command.index("--port") + 1], "4321")
        self.assertEqual(command[command.index("--timeout-s") + 1], "7.5")
        self.assertEqual(command[command.index("--program-mode") + 1], "auto")
        self.assertIn("--yes", command)

    def test_ila_report_command_disables_programming_by_default(self):
        config = waveform_gui_model.IlaReportConfig(artifact_dir=Path("/tmp/artifacts"))
        connection = waveform_gui_model.ConnectionConfig()

        command = waveform_gui_model.build_ila_report_command(config, connection)

        self.assertEqual(command[command.index("--program-mode") + 1], "never")
        self.assertNotIn("--yes", command)

    def test_ila_report_runner_parses_success_paths(self):
        calls = []

        def fake_runner(command):
            calls.append(command)
            return subprocess.CompletedProcess(
                command,
                0,
                stdout="overall_status=PASS\nmarkdown_report=software/ila_reports/ila_capture_report.md\njson_report=software/ila_reports/ila_capture_report.json\n",
                stderr="",
            )

        config = waveform_gui_model.IlaReportConfig(artifact_dir=Path("software/waveform_out"))
        connection = waveform_gui_model.ConnectionConfig(ip="192.0.2.80", port=8080)

        result = waveform_gui_model.run_ila_capture_report(config, connection, runner=fake_runner)

        self.assertTrue(result.ok)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.overall_status, "PASS")
        self.assertEqual(result.markdown_report, Path("software/ila_reports/ila_capture_report.md"))
        self.assertEqual(result.json_report, Path("software/ila_reports/ila_capture_report.json"))
        self.assertEqual(calls[0][0], sys.executable)
        self.assertIn("ila report: software/ila_reports/ila_capture_report.md", result.log_lines)
        self.assertIn("ila status: PASS", result.log_lines)

    def test_ila_report_runner_logs_failure_stdout_and_stderr(self):
        def fake_runner(command):
            return subprocess.CompletedProcess(
                command,
                1,
                stdout="starting\nlast stdout line\n",
                stderr="vivado missing\n",
            )

        config = waveform_gui_model.IlaReportConfig(artifact_dir=Path("software/waveform_out"))
        connection = waveform_gui_model.ConnectionConfig(ip="192.0.2.90", port=9090)

        result = waveform_gui_model.run_ila_capture_report(config, connection, runner=fake_runner)

        self.assertFalse(result.ok)
        self.assertEqual(result.returncode, 1)
        joined = "\n".join(result.log_lines)
        self.assertIn("ila subprocess exit: 1", joined)
        self.assertIn("stdout: last stdout line", joined)
        self.assertIn("stderr: vivado missing", joined)


if __name__ == "__main__":
    unittest.main()
