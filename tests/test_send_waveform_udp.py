import sys
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SOFTWARE_DIR = ROOT / "software"
sys.path.insert(0, str(SOFTWARE_DIR))

import host  # type: ignore[import-not-found]  # noqa: E402
import send_waveform_udp  # type: ignore[import-not-found]  # noqa: E402


class SendWaveformUdpTests(unittest.TestCase):
    def test_cli_default_sample_rate_matches_custom_rfdc_config(self):
        args = send_waveform_udp.build_parser().parse_args(["sine", "--dry-run"])

        self.assertEqual(args.sample_rate_hz, 1_000_000_000.0)

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


if __name__ == "__main__":
    unittest.main()
