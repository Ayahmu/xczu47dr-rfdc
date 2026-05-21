import struct
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
golden = load_software_module("send_golden_pattern_udp", "send_golden_pattern_udp.py")


class GoldenPatternTests(unittest.TestCase):
    def test_incrementing_pattern_has_unambiguous_first_axi_word(self):
        samples = golden.make_incrementing_pattern(sample_count=8, start=0)

        np.testing.assert_array_equal(samples, np.arange(8, dtype=np.int16))
        self.assertEqual(golden.expected_axi_wdata_hex(samples), "0x00070006000500040003000200010000")
        self.assertEqual(golden.lane_bytes_hex(samples), "00 00 01 00 02 00 03 00 04 00 05 00 06 00 07 00")

    def test_first_waveform_packet_matches_rtl_parser_contract(self):
        samples = golden.make_incrementing_pattern(sample_count=8, start=0)
        packet = next(host.iter_udp_waveform_packets(samples, host.DDR_X_ADDR, sample_count=8))

        magic, addr, low, high = struct.unpack("<QQQQ", packet)
        self.assertEqual(magic, host.UDP_WAVE_DDR_MAGIC)
        self.assertEqual(addr, 0x0000000000000000)
        self.assertEqual(low, 0x0003000200010000)
        self.assertEqual(high, 0x0007000600050004)

    def test_play_instruction_hex_matches_executor_decode(self):
        instruction = golden.play_instruction_words(channel=1, length_bytes=host.FIXED_DATA_BYTES, ddr_addr=host.DDR_X_ADDR)

        self.assertEqual(instruction, (0x0000100000000012, 0x0000000000000000))
        self.assertEqual(golden.rtl_instruction_tdata_hex(instruction), "0x00000000000000000000100000000012")

    def test_loop_end_instruction_uses_reserved_bit(self):
        words = (0x0000000000000000, 0x00000000000001f3)
        self.assertEqual(golden.rtl_instruction_tdata_hex(words), "0x00000000000001f30000000000000000")


if __name__ == "__main__":
    unittest.main()
