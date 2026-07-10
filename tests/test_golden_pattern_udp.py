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
waveform_tools = load_software_module("waveform_tools", "waveform_tools.py")


class GoldenPatternTests(unittest.TestCase):
    def test_incrementing_pattern_has_unambiguous_first_axi_word(self):
        samples = waveform_tools.make_incrementing_pattern(sample_count=16, start=0)

        np.testing.assert_array_equal(samples, np.arange(16, dtype=np.int16))
        self.assertEqual(waveform_tools.expected_axi_wdata_hex(samples), "0x000f000e000d000c000b000a0009000800070006000500040003000200010000")
        self.assertEqual(waveform_tools.lane_bytes_hex(samples), "00 00 01 00 02 00 03 00 04 00 05 00 06 00 07 00 08 00 09 00 0a 00 0b 00 0c 00 0d 00 0e 00 0f 00")

    def test_first_waveform_packet_matches_rtl_parser_contract(self):
        samples = waveform_tools.make_incrementing_pattern(sample_count=16, start=0)
        packet = next(host.iter_udp_waveform_packets(samples, host.DDR_X_ADDR, sample_count=16))

        magic, addr, word0, word1, word2, word3 = struct.unpack("<QQQQQQ", packet)
        self.assertEqual(magic, host.UDP_WAVE_DDR_MAGIC)
        self.assertEqual(addr, host.DDR_BASE)
        self.assertEqual(word0, 0x0003000200010000)
        self.assertEqual(word1, 0x0007000600050004)
        self.assertEqual(word2, 0x000b000a00090008)
        self.assertEqual(word3, 0x000f000e000d000c)

    def test_play_instruction_hex_matches_executor_decode(self):
        instruction = waveform_tools.play_instruction_words(channel=1, length_bytes=host.FIXED_DATA_BYTES, ddr_addr=host.DDR_X_ADDR)

        self.assertEqual(instruction, (0x0000100000000012, host.DDR_BASE))
        self.assertEqual(waveform_tools.rtl_instruction_tdata_hex(instruction), "0x00000000000000000000100000000012")

    def test_loop_end_instruction_uses_reserved_bit(self):
        words = (0x0000000000000000, 0x00000000000001f3)
        self.assertEqual(waveform_tools.rtl_instruction_tdata_hex(words), "0x00000000000001f30000000000000000")


if __name__ == "__main__":
    unittest.main()
