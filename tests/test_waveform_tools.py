import sys
import unittest
from importlib import util
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SOFTWARE_DIR = ROOT / "software"
sys.path.insert(0, str(SOFTWARE_DIR))


def load_software_module(module_name: str, filename: str):
    spec = util.spec_from_file_location(module_name, SOFTWARE_DIR / filename)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {filename}")
    module = util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


host = load_software_module("host", "host.py")
waveform_tools = load_software_module("waveform_tools", "waveform_tools.py")


class WaveformToolTests(unittest.TestCase):
    def test_sine_frequency_changes_generated_samples(self):
        low = waveform_tools.make_sine(
            freq_hz=20e6,
            phase_rad=0.0,
            amplitude=20000,
            sample_rate_hz=host.DAC_XY_FS,
            sample_count=host.NUM_SAMPLES,
            encoding="signed",
        )
        high = waveform_tools.make_sine(
            freq_hz=80e6,
            phase_rad=0.0,
            amplitude=20000,
            sample_rate_hz=host.DAC_XY_FS,
            sample_count=host.NUM_SAMPLES,
            encoding="signed",
        )

        self.assertEqual(low.dtype, np.int16)
        self.assertEqual(high.dtype, np.int16)
        self.assertEqual(len(low), host.NUM_SAMPLES)
        self.assertEqual(len(high), host.NUM_SAMPLES)
        self.assertFalse(np.array_equal(low, high))

    def test_sine_sample_rate_changes_generated_samples(self):
        default_rate = waveform_tools.make_sine(
            freq_hz=20e6,
            phase_rad=0.0,
            amplitude=20000,
            sample_rate_hz=host.DAC_XY_FS,
            sample_count=host.NUM_SAMPLES,
            encoding="signed",
        )
        half_rate = waveform_tools.make_sine(
            freq_hz=20e6,
            phase_rad=0.0,
            amplitude=20000,
            sample_rate_hz=host.DAC_XY_FS / 2.0,
            sample_count=host.NUM_SAMPLES,
            encoding="signed",
        )

        self.assertFalse(np.array_equal(default_rate, half_rate))

    def test_gaussian_burst_produces_nonzero_samples(self):
        burst = waveform_tools.make_gaussian_burst(
            freq_hz=80e6,
            phase_rad=0.0,
            amplitude=24000,
            sample_rate_hz=host.DAC_XY_FS,
            duration_s=120e-9,
            delay_s=80e-9,
            sample_count=host.NUM_SAMPLES,
        )

        self.assertEqual(burst.dtype, np.int16)
        self.assertEqual(len(burst), host.NUM_SAMPLES)
        self.assertGreater(np.max(np.abs(burst)), 1000)

    def test_golden_helpers_match_expected_hex(self):
        samples = waveform_tools.make_incrementing_pattern(sample_count=8, start=0)

        self.assertEqual(waveform_tools.expected_axi_wdata_hex(samples), "0x00070006000500040003000200010000")
        self.assertEqual(waveform_tools.lane_bytes_hex(samples), "00 00 01 00 02 00 03 00 04 00 05 00 06 00 07 00")
        self.assertEqual(
            waveform_tools.rtl_instruction_tdata_hex(waveform_tools.play_instruction_words(1, host.FIXED_DATA_BYTES, host.DDR_X_ADDR)),
            "0x00000000000000000000100000000012",
        )

    def test_build_play_commands_encodes_loop_and_trigger_modes(self):
        loop_cmds = waveform_tools.build_play_commands(loop=True, auto_start=True)
        trigger_cmds = waveform_tools.build_play_commands(loop=False, auto_start=False)

        self.assertEqual(loop_cmds[-1], [3, 15, 0, 0, 1])
        self.assertEqual(trigger_cmds[-1], [3, 0, 0, 0, 0])

    def test_waveform_metadata_uses_explicit_units(self):
        metadata = waveform_tools.build_metadata(
            mode="sine",
            sample_rate_hz=host.DAC_XY_FS,
            x_freq_hz=20e6,
            y_freq_hz=40e6,
            encoding="signed",
            loop=True,
        )

        self.assertEqual(metadata["sample_rate_hz"], host.DAC_XY_FS)
        self.assertEqual(metadata["samples_per_channel"], host.NUM_SAMPLES)
        self.assertEqual(metadata["bytes_per_channel"], host.FIXED_DATA_BYTES)
        self.assertEqual(metadata["x_freq_hz"], 20e6)
        self.assertEqual(metadata["y_freq_hz"], 40e6)
        self.assertTrue(metadata["loop"])


if __name__ == "__main__":
    unittest.main()
