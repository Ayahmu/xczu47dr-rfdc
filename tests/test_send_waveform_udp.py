import sys
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SOFTWARE_DIR = ROOT / "software"
sys.path.insert(0, str(SOFTWARE_DIR))

import host  # type: ignore[import-not-found]  # noqa: E402
import send_waveform_udp  # type: ignore[import-not-found]  # noqa: E402


class SendWaveformUdpTests(unittest.TestCase):
    def test_cli_default_sample_rate_matches_custom_rfdc_config(self):
        args = send_waveform_udp.build_parser().parse_args(["sine", "--dry-run"])

        self.assertEqual(args.sample_rate_hz, 1_200_000_000.0)

    def test_cli_default_axis_frequency_matches_custom_rfdc_axis_clock(self):
        args = send_waveform_udp.build_parser().parse_args(["burst", "--dry-run"])

        self.assertEqual(args.axis_freq_hz, 300_000_000.0)

    def test_sine_cli_generates_four_channels_and_metadata(self):
        args = send_waveform_udp.build_parser().parse_args([
            "sine",
            "--dry-run",
            "--ch1-freq-hz", "20000000",
            "--ch2-freq-hz", "30000000",
            "--ch3-freq-hz", "40000000",
            "--ch4-freq-hz", "50000000",
        ])

        ch1, ch2, ch3, ch4, metadata = send_waveform_udp.generate_waveforms(args)

        self.assertEqual(ch1.dtype, np.int16)
        self.assertEqual(ch2.dtype, np.int16)
        self.assertEqual(ch3.dtype, np.int16)
        self.assertEqual(ch4.dtype, np.int16)
        self.assertEqual(len(ch4), host.NUM_SAMPLES)
        self.assertFalse(np.array_equal(ch1, ch3))
        self.assertEqual(metadata["ch1_freq_hz"], 20e6)
        self.assertEqual(metadata["ch2_freq_hz"], 30e6)
        self.assertEqual(metadata["ch3_freq_hz"], 40e6)
        self.assertEqual(metadata["ch4_freq_hz"], 50e6)

    def test_legacy_xy_args_override_ch1_ch2_only(self):
        args = send_waveform_udp.build_parser().parse_args([
            "golden",
            "--dry-run",
            "--x-start", "16",
            "--y-start", "32",
            "--ch3-start", "48",
            "--ch4-start", "64",
        ])

        ch1, ch2, ch3, ch4, metadata = send_waveform_udp.generate_waveforms(args)

        self.assertEqual(ch1[:4].view(np.uint16).tolist(), [16, 17, 18, 19])
        self.assertEqual(ch2[:4].view(np.uint16).tolist(), [32, 33, 34, 35])
        self.assertEqual(ch3[:4].view(np.uint16).tolist(), [48, 49, 50, 51])
        self.assertEqual(ch4[:4].view(np.uint16).tolist(), [64, 65, 66, 67])
        self.assertEqual(metadata["ch1_start"], 16)
        self.assertEqual(metadata["ch2_start"], 32)
        self.assertEqual(metadata["ch3_start"], 48)
        self.assertEqual(metadata["ch4_start"], 64)

    def test_burst_cli_sends_hardware_delay_cycles_from_ns_and_axis_frequency(self):
        output_dir = Path("/tmp/send-waveform-delay-test")
        argv = [
            "send_waveform_udp.py",
            "burst",
            "--axis-freq-hz", "300000000",
            "--ch1-delay-s", "80e-9",
            "--ch2-delay-s", "120e-9",
            "--ch3-delay-s", "160e-9",
            "--ch4-delay-s", "200e-9",
            "--output-dir", str(output_dir),
        ]

        with mock.patch.object(sys, "argv", argv), \
             mock.patch.object(send_waveform_udp.waveform_tools, "save_waveform_bundle"), \
             mock.patch.object(send_waveform_udp.waveform_tools, "upload_and_play") as upload:
            self.assertEqual(send_waveform_udp.main(), 0)

        self.assertEqual(upload.call_args.kwargs["channel_delays"], {1: 24, 2: 36, 3: 48, 4: 60})

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
        self.assertEqual(delayed[4]["ch1_delay_cycles"], 24)
        self.assertEqual(delayed[4]["ch2_delay_cycles"], 36)
        self.assertEqual(delayed[4]["ch3_delay_cycles"], 48)
        self.assertEqual(delayed[4]["ch4_delay_cycles"], 60)


if __name__ == "__main__":
    unittest.main()
