import sys
import unittest
import tempfile
from pathlib import Path
from unittest import mock

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SOFTWARE_DIR = ROOT / "software"
sys.path.insert(0, str(SOFTWARE_DIR))

import host  # type: ignore[import-not-found]  # noqa: E402
import send_waveform_udp  # type: ignore[import-not-found]  # noqa: E402
import waveform_tools  # type: ignore[import-not-found]  # noqa: E402


class SendWaveformUdpTests(unittest.TestCase):
    def test_cli_default_sample_rate_matches_custom_rfdc_config(self):
        args = send_waveform_udp.build_parser().parse_args(["sine", "--dry-run"])

        self.assertEqual(args.sample_rate_hz, 400_000_000.0)
        self.assertEqual(args.ddr_layout, host.DDR_LAYOUT_INTERLEAVED_512B)

    def test_cli_default_axis_frequency_matches_custom_rfdc_axis_clock(self):
        args = send_waveform_udp.build_parser().parse_args(["burst", "--dry-run"])

        self.assertEqual(args.axis_freq_hz, 50_000_000.0)

    def test_max_length_cli_defaults_to_usable_ddr_limit(self):
        args = send_waveform_udp.build_parser().parse_args(["max-length", "--dry-run"])
        metadata = send_waveform_udp.max_length_metadata(args)

        self.assertEqual(args.bytes_per_channel, host.DDR_MAX_BYTES_PER_CHANNEL)
        self.assertEqual(metadata["physical_ddr_bytes"], 0x1FFF00000)
        self.assertEqual(metadata["expected_rfdc_beats_per_channel"], 33_550_336)
        self.assertEqual(metadata["expected_datamover_beats"], 134_201_344)
        self.assertAlmostEqual(metadata["expected_duration_s"], 0.67100672)

    def test_max_length_cli_streams_without_allocating_channel_arrays(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            controller = mock.Mock()
            argv = [
                "send_waveform_udp.py",
                "max-length",
                "--bytes-per-channel", "4KiB",
                "--wait-for-trigger",
                "--output-dir", temp_dir,
            ]
            with mock.patch.object(sys, "argv", argv), \
                 mock.patch.object(send_waveform_udp.host, "RFSocController", return_value=controller):
                self.assertEqual(send_waveform_udp.main(), 0)

            controller.upload_max_length_udp.assert_called_once()
            self.assertEqual(controller.upload_max_length_udp.call_args.args[0], 4096)
            commands = controller.send_instructions.call_args.args[0]
            play_commands = [command for command in commands if command[0] == 2]
            self.assertEqual(len(play_commands), 8)
            self.assertTrue(all(command[2] == 4096 for command in play_commands))
            self.assertEqual(commands[-1], [3, 0, 0, 0, 0])
            metadata_path = Path(temp_dir) / "max_length_metadata.json"
            self.assertTrue(metadata_path.exists())

    def test_rvctrl_cli_commands_use_control_packet_path(self):
        cases = [
            (
                ["send_waveform_udp.py", "rvctrl-ping", "--seq", "11"],
                "rvctrl_ping",
                (11,),
            ),
            (
                ["send_waveform_udp.py", "rvctrl-play", "--bytes-per-channel", "4KiB", "--seq", "12", "--auto-start", "--loop"],
                "rvctrl_play_interleaved",
                (4096,),
            ),
            (
                ["send_waveform_udp.py", "rvctrl-trigger", "--seq", "13"],
                "rvctrl_trigger",
                (13,),
            ),
        ]

        for argv, method_name, first_args in cases:
            with self.subTest(method_name=method_name):
                controller = mock.Mock()
                with mock.patch.object(sys, "argv", argv), \
                     mock.patch.object(send_waveform_udp.host, "RFSocController", return_value=controller):
                    self.assertEqual(send_waveform_udp.main(), 0)

                method = getattr(controller, method_name)
                method.assert_called_once()
                for index, expected in enumerate(first_args):
                    self.assertEqual(method.call_args.args[index], expected)

    def test_rvctrl_play_cli_passes_auto_start_and_loop_flags(self):
        controller = mock.Mock()
        argv = [
            "send_waveform_udp.py",
            "rvctrl-play",
            "--bytes-per-channel", "4096",
            "--seq", "14",
            "--auto-start",
            "--loop",
        ]
        with mock.patch.object(sys, "argv", argv), \
             mock.patch.object(send_waveform_udp.host, "RFSocController", return_value=controller):
            self.assertEqual(send_waveform_udp.main(), 0)

        controller.rvctrl_play_interleaved.assert_called_once_with(
            4096,
            seq=14,
            auto_start=True,
            loop=True,
        )

    def test_rvctrl1_cli_commands_use_control_packet_path(self):
        cases = [
            (
                ["send_waveform_udp.py", "rvctrl1-ping", "--seq", "21"],
                "rvctrl1_ping",
                (21,),
            ),
            (
                ["send_waveform_udp.py", "rvctrl1-mmio-write", "--addr", "0x120", "--value", "0xCAFE1234", "--seq", "22"],
                "rvctrl1_mmio_write32",
                (0x120, 0xCAFE1234),
            ),
            (
                ["send_waveform_udp.py", "rvctrl1-mmio-rmw", "--addr", "0x124", "--mask", "0xff", "--value", "0x55", "--seq", "23"],
                "rvctrl1_mmio_rmw32",
                (0x124, 0xff, 0x55),
            ),
            (
                ["send_waveform_udp.py", "rvctrl1-mmio-batch", "--write", "0x10=0x11", "--write", "0x20=0x22", "--seq", "24"],
                "rvctrl1_mmio_batch",
                ([(0x10, 0x11), (0x20, 0x22)],),
            ),
            (
                ["send_waveform_udp.py", "rvctrl1-rfdc-ch-enable", "--channel-mask", "0x03", "--enable-mask", "0x01", "--seq", "25"],
                "rvctrl1_rfdc_ch_enable",
                (0x03, 0x01),
            ),
            (
                ["send_waveform_udp.py", "rvctrl1-rfdc-set-nco", "--nco", "1=100e6", "--zone", "1=2", "--apply-mask", "0x01", "--seq", "26"],
                "rvctrl1_rfdc_set_nco",
                ({1: 100e6}, {1: 2}),
            ),
        ]

        for argv, method_name, expected_args in cases:
            with self.subTest(method_name=method_name):
                controller = mock.Mock()
                with mock.patch.object(sys, "argv", argv), \
                     mock.patch.object(send_waveform_udp.host, "RFSocController", return_value=controller):
                    self.assertEqual(send_waveform_udp.main(), 0)

                method = getattr(controller, method_name)
                method.assert_called_once()
                for index, expected in enumerate(expected_args):
                    self.assertEqual(method.call_args.args[index], expected)

    def test_rvctrl1_play_cli_passes_auto_start_and_loop_flags(self):
        controller = mock.Mock()
        argv = [
            "send_waveform_udp.py",
            "rvctrl1-play",
            "--bytes-per-channel", "4096",
            "--seq", "25",
            "--auto-start",
            "--loop",
        ]
        with mock.patch.object(sys, "argv", argv), \
             mock.patch.object(send_waveform_udp.host, "RFSocController", return_value=controller):
            self.assertEqual(send_waveform_udp.main(), 0)

        controller.rvctrl1_play_interleaved.assert_called_once_with(
            4096,
            seq=25,
            auto_start=True,
            loop=True,
            wait_response=False,
        )

    def test_max_length_cli_dry_run_does_not_generate_cache_unless_requested(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            argv = [
                "send_waveform_udp.py",
                "max-length",
                "--bytes-per-channel", "4KiB",
                "--dry-run",
                "--output-dir", temp_dir,
            ]
            with mock.patch.object(sys, "argv", argv):
                self.assertEqual(send_waveform_udp.main(), 0)
            self.assertFalse((Path(temp_dir) / "waveform_cache").exists())

            argv = [
                "send_waveform_udp.py",
                "max-length",
                "--bytes-per-channel", "4KiB",
                "--generate-cache-only",
                "--output-dir", temp_dir,
            ]
            with mock.patch.object(sys, "argv", argv):
                self.assertEqual(send_waveform_udp.main(), 0)
            self.assertTrue(any((Path(temp_dir) / "waveform_cache").glob("*.bin")))

    def test_sine_cli_generates_eight_channels_and_metadata(self):
        args = send_waveform_udp.build_parser().parse_args([
            "sine",
            "--dry-run",
            "--ch1-freq-hz", "20000000",
            "--ch2-freq-hz", "30000000",
            "--ch3-freq-hz", "40000000",
            "--ch4-freq-hz", "50000000",
            "--ch5-freq-hz", "60000000",
            "--ch6-freq-hz", "70000000",
            "--ch7-freq-hz", "80000000",
            "--ch8-freq-hz", "90000000",
        ])

        *waves, metadata = send_waveform_udp.generate_waveforms(args)
        expected_len = (
            waveform_tools.iq_duration_to_sample_count(args.duration_s, args.sample_rate_hz)
            + waveform_tools.iq_duration_to_sample_count(send_waveform_udp.resolve_sine_zero_tail_s(args), args.sample_rate_hz)
        )

        self.assertEqual(len(waves), 8)
        for wave in waves:
            self.assertEqual(wave.dtype, np.int16)
            self.assertEqual(len(wave), expected_len)
            self.assertFalse(np.any(wave[-16:]))
        self.assertFalse(np.array_equal(waves[0], waves[7]))
        self.assertFalse(metadata["loop"])
        self.assertEqual(metadata["duration_s"], 1e-6)
        self.assertEqual(metadata["zero_tail_s"], 50e-9)
        self.assertEqual(metadata["bytes_per_channel"], expected_len * 2)
        self.assertEqual(metadata["ch1_freq_hz"], 20e6)
        self.assertEqual(metadata["ch2_freq_hz"], 30e6)
        self.assertEqual(metadata["ch3_freq_hz"], 40e6)
        self.assertEqual(metadata["ch4_freq_hz"], 50e6)
        self.assertEqual(metadata["ch8_freq_hz"], 90e6)

    def test_sine_cli_loop_flag_reaches_metadata_and_uploader(self):
        output_dir = Path("/tmp/send-waveform-loop-test")
        argv = [
            "send_waveform_udp.py",
            "sine",
            "--loop",
            "--output-dir", str(output_dir),
        ]

        with mock.patch.object(sys, "argv", argv), \
             mock.patch.object(send_waveform_udp.waveform_tools, "save_waveform_bundle") as save_bundle, \
             mock.patch.object(send_waveform_udp.waveform_tools, "upload_and_play") as upload:
            self.assertEqual(send_waveform_udp.main(), 0)

        metadata = save_bundle.call_args.args[3]
        self.assertTrue(metadata["loop"])
        self.assertTrue(upload.call_args.kwargs["loop"])

    def test_sine_cli_rejects_nonperiodic_loop_tone(self):
        output_dir = Path("/tmp/send-waveform-nonperiodic-loop-test")
        argv = [
            "send_waveform_udp.py",
            "sine",
            "--loop",
            "--duration-s", "1e-6",
            "--ch1-freq-hz", "20500000",
            "--output-dir", str(output_dir),
        ]

        with mock.patch.object(sys, "argv", argv), \
             mock.patch.object(send_waveform_udp.waveform_tools, "save_waveform_bundle") as save_bundle, \
             mock.patch.object(send_waveform_udp.waveform_tools, "upload_and_play") as upload:
            self.assertEqual(send_waveform_udp.main(), 1)

        save_bundle.assert_not_called()
        upload.assert_not_called()

    def test_pypulse_cli_generates_eight_interleaved_iq_buffers_and_metadata(self):
        args = send_waveform_udp.build_parser().parse_args([
            "pypulse",
            "--dry-run",
            "--xy-freq-hz", "90000000",
            "--readout-freq-hz", "140000000",
            "--amplitude", "21000",
        ])

        *waves, metadata = send_waveform_udp.generate_waveforms(args)

        self.assertEqual(len(waves), 8)
        for wave in waves:
            self.assertEqual(wave.dtype, np.int16)
            self.assertEqual(len(wave), host.NUM_SAMPLES)
        self.assertEqual(metadata["mode"], "pypulse")
        self.assertEqual(metadata["encoding"], "signed-iq-interleaved")
        self.assertEqual(metadata["ch1_pypulse_waveform"], "xy")
        self.assertEqual(metadata["ch2_pypulse_waveform"], "z")
        self.assertEqual(metadata["ch3_pypulse_waveform"], "readout")
        self.assertEqual(metadata["ch5_pypulse_waveform"], "xy")
        self.assertEqual(metadata["ch6_pypulse_waveform"], "z")
        self.assertEqual(metadata["ch7_pypulse_waveform"], "readout")
        self.assertFalse(np.any(waves[1][1::2]))
        self.assertFalse(np.any(waves[5][1::2]))
        self.assertEqual(metadata["ch2_q_signal"], "zero_q")
        self.assertEqual(metadata["xy_freq_hz"], 90e6)
        self.assertEqual(metadata["readout_freq_hz"], 140e6)

    def test_channel_arguments_set_each_channel_independently(self):
        args = send_waveform_udp.build_parser().parse_args([
            "golden",
            "--dry-run",
            "--ch1-start", "16",
            "--ch2-start", "32",
            "--ch3-start", "48",
            "--ch4-start", "64",
        ])

        *waves, metadata = send_waveform_udp.generate_waveforms(args)

        self.assertEqual(waves[0][:4].view(np.uint16).tolist(), [16, 17, 18, 19])
        self.assertEqual(waves[1][:4].view(np.uint16).tolist(), [32, 33, 34, 35])
        self.assertEqual(waves[2][:4].view(np.uint16).tolist(), [48, 49, 50, 51])
        self.assertEqual(waves[3][:4].view(np.uint16).tolist(), [64, 65, 66, 67])
        ch8_start = host.DDR_CH8_ADDR & 0xFFFF
        self.assertEqual(waves[7][:4].view(np.uint16).tolist(), [ch8_start, ch8_start + 1, ch8_start + 2, ch8_start + 3])
        self.assertEqual(metadata["ch1_start"], 16)
        self.assertEqual(metadata["ch2_start"], 32)
        self.assertEqual(metadata["ch3_start"], 48)
        self.assertEqual(metadata["ch4_start"], 64)

    def test_removed_channel_alias_options_are_rejected(self):
        with self.assertRaises(SystemExit):
            send_waveform_udp.build_parser().parse_args([
                "sine", "--dry-run", "--x-freq-hz", "1000000",
            ])

    def test_default_channel_start_addresses_match_32b_aligned_ddr_layout(self):
        self.assertEqual(send_waveform_udp.CHANNEL_DEFAULTS[1]["start"], host.DDR_CH1_ADDR)
        self.assertEqual(send_waveform_udp.CHANNEL_DEFAULTS[2]["start"], host.DDR_CH2_ADDR)
        self.assertEqual(send_waveform_udp.CHANNEL_DEFAULTS[8]["start"], host.DDR_CH8_ADDR)

    def test_burst_cli_does_not_send_hardware_delays_for_interleaved_layout(self):
        output_dir = Path("/tmp/send-waveform-delay-test")
        argv = [
            "send_waveform_udp.py",
            "burst",
            "--axis-freq-hz", "300000000",
            "--ch1-delay-s", "80e-9",
            "--ch2-delay-s", "120e-9",
            "--ch3-delay-s", "160e-9",
            "--ch4-delay-s", "200e-9",
            "--ch5-delay-s", "240e-9",
            "--ch6-delay-s", "280e-9",
            "--ch7-delay-s", "320e-9",
            "--ch8-delay-s", "360e-9",
            "--output-dir", str(output_dir),
        ]

        with mock.patch.object(sys, "argv", argv), \
             mock.patch.object(send_waveform_udp.waveform_tools, "save_waveform_bundle"), \
             mock.patch.object(send_waveform_udp.waveform_tools, "upload_and_play") as upload:
            self.assertEqual(send_waveform_udp.main(), 0)

        self.assertIsNone(upload.call_args.kwargs["channel_delays"])

    def test_burst_cli_sends_hardware_delay_cycles_for_legacy_tiled_layout(self):
        output_dir = Path("/tmp/send-waveform-delay-test")
        argv = [
            "send_waveform_udp.py",
            "burst",
            "--ddr-layout", host.DDR_LAYOUT_TILED,
            "--axis-freq-hz", "300000000",
            "--ch1-delay-s", "80e-9",
            "--ch2-delay-s", "120e-9",
            "--ch3-delay-s", "160e-9",
            "--ch4-delay-s", "200e-9",
            "--ch5-delay-s", "240e-9",
            "--ch6-delay-s", "280e-9",
            "--ch7-delay-s", "320e-9",
            "--ch8-delay-s", "360e-9",
            "--output-dir", str(output_dir),
        ]

        with mock.patch.object(sys, "argv", argv), \
             mock.patch.object(send_waveform_udp.waveform_tools, "save_waveform_bundle"), \
             mock.patch.object(send_waveform_udp.waveform_tools, "upload_and_play") as upload:
            self.assertEqual(send_waveform_udp.main(), 0)

        self.assertEqual(upload.call_args.kwargs["channel_delays"], {1: 24, 2: 36, 3: 48, 4: 60, 5: 72, 6: 84, 7: 96, 8: 108})

    def test_burst_cli_delay_does_not_pad_generated_waveforms(self):
        base_args = send_waveform_udp.build_parser().parse_args([
            "burst",
            "--ch1-delay-s", "0",
            "--ch2-delay-s", "0",
            "--ch3-delay-s", "0",
            "--ch4-delay-s", "0",
        ])
        delayed_args = send_waveform_udp.build_parser().parse_args([
            "burst",
            "--axis-freq-hz", "300000000",
            "--ch1-delay-s", "80e-9",
            "--ch2-delay-s", "120e-9",
            "--ch3-delay-s", "160e-9",
            "--ch4-delay-s", "200e-9",
        ])

        base = send_waveform_udp.generate_waveforms(base_args)
        delayed = send_waveform_udp.generate_waveforms(delayed_args)

        for channel in range(4):
            np.testing.assert_array_equal(base[channel], delayed[channel])
        metadata = delayed[-1]
        self.assertEqual(metadata["ch1_delay_cycles"], 24)
        self.assertEqual(metadata["ch2_delay_cycles"], 36)
        self.assertEqual(metadata["ch3_delay_cycles"], 48)
        self.assertEqual(metadata["ch4_delay_cycles"], 60)
        self.assertEqual(metadata["ch8_delay_cycles"], 108)

    def test_ezq_cli_parses_artifact_directory_mode(self):
        args = send_waveform_udp.build_parser().parse_args([
            "ezq",
            "--artifact-dir", "/tmp/ezq-artifacts",
            "--dry-run",
        ])

        self.assertEqual(args.mode, "ezq")
        self.assertEqual(args.artifact_dir, Path("/tmp/ezq-artifacts"))
        self.assertEqual(args.wave_format, "packed_iq")

    def test_ezq_loader_round_trips_saved_artifacts(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            out_dir = Path(temp_dir)
            wave = np.array([1, 10, 2, 20, 3, 30, 4, 40], dtype=np.int16)
            metadata = {
                "mode": "iq-sine",
                "layout": host.DDR_LAYOUT_TILED,
                "ch1_delay_cycles": 24,
            }
            waveform_tools.save_ezq_wave_bundle(
                out_dir,
                {1: wave},
                metadata,
                channel_format="interleaved_iq",
                stem="ezq",
            )

            loader_args = send_waveform_udp.build_parser().parse_args([
                "ezq",
                "--artifact-dir", str(out_dir),
                "--dry-run",
            ])
            channel_waves, channel_sequences, loaded_metadata = send_waveform_udp._load_ezq_channel_artifacts(loader_args)

            self.assertEqual(sorted(channel_waves), [1])
            np.testing.assert_array_equal(channel_waves[1], wave)
            self.assertEqual(sorted(channel_sequences), [1])
            self.assertEqual(int(channel_sequences[1][0][1]), len(wave) // 4)
            self.assertEqual(loaded_metadata["mode"], "iq-sine")

    def test_ezq_cli_loop_flag_reaches_play_commands(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            artifact_dir = Path(temp_dir) / "artifacts"
            output_dir = Path(temp_dir) / "upload"
            wave = np.array([1, 10, 2, 20, 3, 30, 4, 40], dtype=np.int16)
            waveform_tools.save_ezq_wave_bundle(
                artifact_dir,
                {1: wave},
                {"mode": "ezq", "layout": host.DDR_LAYOUT_INTERLEAVED_512B},
                channel_format="interleaved_iq",
                stem="ezq",
            )
            controller = mock.Mock()
            argv = [
                "send_waveform_udp.py",
                "ezq",
                "--artifact-dir", str(artifact_dir),
                "--wave-format", "interleaved_iq",
                "--channels", "1",
                "--loop",
                "--output-dir", str(output_dir),
            ]

            with mock.patch.object(sys, "argv", argv), \
                 mock.patch.object(send_waveform_udp.host, "RFSocController", return_value=controller):
                self.assertEqual(send_waveform_udp.main(), 0)

            commands = controller.send_instructions.call_args.args[0]
            self.assertEqual(commands[-1], [3, 15, 0, 0, 1])


if __name__ == "__main__":
    unittest.main()
