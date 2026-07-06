import struct
import sys
import unittest
from importlib import util
from pathlib import Path
from unittest import mock

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


class UdpWaveformPacketTests(unittest.TestCase):
    def test_default_sample_rate_matches_custom_rfdc_config(self):
        self.assertEqual(host.DAC_TILE_FS, 6_000_000_000.0)
        self.assertEqual(host.DAC_XY_FS, 750_000_000.0)
        self.assertEqual(host.DAC_AXIS_HZ, 93_750_000.0)
        self.assertEqual(host.RFDC_INTERPOLATION, 8)

    def test_default_ddr_addresses_match_bd_mapped_base(self):
        self.assertEqual(host.DDR_BASE, 0x0000000000000000)
        self.assertEqual(host.DDR_CH_STRIDE, host.TONE_BYTES_DEFAULT)
        self.assertEqual(host.DDR_TILE_BYTES, 4096)
        self.assertEqual(host.DDR_SUPERBLOCK_BYTES, 32768)
        self.assertEqual(host.DDR_CH1_ADDR, 0x0000000000000000)
        self.assertEqual(host.DDR_CH2_ADDR, 0x0000000000040000)
        self.assertEqual(host.DDR_CH3_ADDR, 0x0000000000080000)
        self.assertEqual(host.DDR_CH4_ADDR, 0x00000000000C0000)
        self.assertEqual(host.DDR_CH5_ADDR, 0x0000000000100000)
        self.assertEqual(host.DDR_CH6_ADDR, 0x0000000000140000)
        self.assertEqual(host.DDR_CH7_ADDR, 0x0000000000180000)
        self.assertEqual(host.DDR_CH8_ADDR, 0x00000000001C0000)
        self.assertEqual(host.DDR_CH_ADDR, [
            host.DDR_CH1_ADDR,
            host.DDR_CH2_ADDR,
            host.DDR_CH3_ADDR,
            host.DDR_CH4_ADDR,
            host.DDR_CH5_ADDR,
            host.DDR_CH6_ADDR,
            host.DDR_CH7_ADDR,
            host.DDR_CH8_ADDR,
        ])
        self.assertEqual(host.DDR_X_ADDR, host.DDR_CH1_ADDR)
        self.assertEqual(host.DDR_Y_ADDR, host.DDR_CH2_ADDR)

    def test_tiled_ddr_address_mapping(self):
        self.assertEqual(host.tiled_ddr_addr(1, 0), host.DDR_BASE)
        self.assertEqual(host.tiled_ddr_addr(2, 0), host.DDR_BASE + host.DDR_TILE_BYTES)
        self.assertEqual(host.tiled_ddr_addr(1, host.DDR_TILE_BYTES), host.DDR_BASE + host.DDR_SUPERBLOCK_BYTES)
        self.assertEqual(host.tiled_ddr_addr(8, 32), host.DDR_BASE + 7 * host.DDR_TILE_BYTES + 32)

    def test_tiled_ddr_address_requires_32_byte_alignment(self):
        with self.assertRaisesRegex(ValueError, "byte_offset must be 32B aligned"):
            host.tiled_ddr_addr(1, 2)

    def test_udp_packet_address_requires_32_byte_alignment(self):
        samples = np.arange(16, dtype=np.int16)
        with self.assertRaisesRegex(ValueError, "ddr_addr must be 32B aligned"):
            list(host.iter_udp_waveform_packets(samples, 8, sample_count=16))

    def test_tiled_udp_packets_stride_between_channel_tiles(self):
        samples = np.arange((host.DDR_TILE_BYTES // 2) + 16, dtype=np.int16)
        packets = list(host.iter_tiled_udp_waveform_packets(samples, channel=1))

        first = struct.unpack("<QQQQQQ", packets[0])
        last_tile0 = struct.unpack("<QQQQQQ", packets[(host.DDR_TILE_BYTES // 32) - 1])
        first_tile1 = struct.unpack("<QQQQQQ", packets[host.DDR_TILE_BYTES // 32])

        self.assertEqual(first[1], host.DDR_BASE)
        self.assertEqual(last_tile0[1], host.DDR_BASE + host.DDR_TILE_BYTES - 32)
        self.assertEqual(first_tile1[1], host.DDR_BASE + host.DDR_SUPERBLOCK_BYTES)

    def test_packets_are_256_bit_ddr_writes(self):
        samples = np.arange(16, dtype=np.int16)
        packets = list(host.iter_udp_waveform_packets(samples, host.DDR_X_ADDR, sample_count=16))

        self.assertEqual(len(packets), 1)
        self.assertEqual(len(packets[0]), 48)

        magic, addr, word0, word1, word2, word3 = struct.unpack("<QQQQQQ", packets[0])
        self.assertEqual(magic, host.UDP_WAVE_DDR_MAGIC)
        self.assertEqual(addr, 0x0000000000000000)

        payload = struct.pack("<QQQQ", word0, word1, word2, word3)
        self.assertEqual(payload, samples.astype("<i2").tobytes())
        _, decoded_addr, decoded_payload = host.decode_udp_waveform_packet(packets[0])
        self.assertEqual(decoded_addr, host.DDR_X_ADDR)
        self.assertEqual(decoded_payload, samples.astype("<i2").tobytes())

    def test_dc_iq_tone_uses_interleaved_i_with_zero_q(self):
        tone = host.build_dc_iq_tone(64, amp=0.5)

        self.assertEqual(tone.dtype, np.int16)
        self.assertEqual(len(tone), 32)
        self.assertEqual(int(tone[0]), int(round(0.5 * 32767)))
        self.assertTrue(np.all(tone[0::2] == tone[0]))
        self.assertFalse(np.any(tone[1::2]))

    def test_short_waveform_is_zero_padded(self):
        samples = np.array([1, -1], dtype=np.int16)
        packets = list(host.iter_udp_waveform_packets(samples, host.DDR_Y_ADDR, sample_count=16))

        _, addr, word0, word1, word2, word3 = struct.unpack("<QQQQQQ", packets[0])
        payload = struct.pack("<QQQQ", word0, word1, word2, word3)
        decoded = np.frombuffer(payload, dtype="<i2")

        self.assertEqual(addr, host.DDR_CH2_ADDR)
        np.testing.assert_array_equal(decoded, np.array([1, -1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], dtype=np.int16))

    def test_udp_controller_can_bind_source_interface_and_ip(self):
        class FakeSocket:
            def __init__(self):
                self.calls = []

            def settimeout(self, timeout_s):
                self.calls.append(("settimeout", timeout_s))

            def setsockopt(self, level, optname, value):
                self.calls.append(("setsockopt", level, optname, value))

            def bind(self, addr):
                self.calls.append(("bind", addr))

            def close(self):
                self.calls.append(("close",))

        fake_socket = FakeSocket()
        with mock.patch.object(host.socket, "socket", return_value=fake_socket):
            ctrl = host.RFSocController(
                "192.168.1.128",
                transport="udp",
                udp_interface="enp225s0f0",
                udp_source_ip="192.168.1.10",
            )
            ctrl.close()

        self.assertIn(("setsockopt", host.socket.SOL_SOCKET, host.SO_BINDTODEVICE, b"enp225s0f0\0"), fake_socket.calls)
        self.assertIn(("bind", ("192.168.1.10", 0)), fake_socket.calls)

    def test_send_instructions_encodes_reserved_loop_bit(self):
        class FakeSocket:
            def __init__(self):
                self.calls = []

            def settimeout(self, timeout_s):
                self.calls.append(("settimeout", timeout_s))

            def close(self):
                self.calls.append(("close",))

            def sendto(self, packet, addr):
                self.calls.append(("sendto", packet, addr))
                return len(packet)

        fake_socket = FakeSocket()
        with mock.patch.object(host.socket, "socket", return_value=fake_socket):
            ctrl = host.RFSocController("192.168.1.128", transport="udp")
            ctrl.send_instructions([[3, 15, 0, 0, 1]])
            ctrl.close()

        sendto_calls = [call for call in fake_socket.calls if call[0] == "sendto"]
        self.assertEqual(len(sendto_calls), 1)
        packet = sendto_calls[0][1]
        word0, word1, word2, word3 = struct.unpack("<IIII", packet)
        self.assertEqual(word0, 0x000001f3)
        self.assertEqual(word1, 0)
        self.assertEqual(word2, 0)
        self.assertEqual(word3, 0)

    def test_send_instructions_encodes_tiled_play_flag_without_loop_conflict(self):
        class FakeSocket:
            def __init__(self):
                self.calls = []

            def settimeout(self, timeout_s):
                self.calls.append(("settimeout", timeout_s))

            def close(self):
                self.calls.append(("close",))

            def sendto(self, packet, addr):
                self.calls.append(("sendto", packet, addr))
                return len(packet)

        fake_socket = FakeSocket()
        with mock.patch.object(host.socket, "socket", return_value=fake_socket):
            ctrl = host.RFSocController("192.168.1.128", transport="udp")
            ctrl.send_instructions([[2, 1, host.FIXED_DATA_BYTES, host.tiled_channel_base_addr(1), host.PLAY_FLAG_TILED]])
            ctrl.close()

        packet = [call for call in fake_socket.calls if call[0] == "sendto"][0][1]
        word0, word1, word2, word3 = struct.unpack("<IIII", packet)
        self.assertEqual(word0, 0x00000212)
        self.assertEqual(word1, host.FIXED_DATA_BYTES)
        self.assertEqual(word2, host.tiled_channel_base_addr(1))
        self.assertEqual(word3, 0)

    def test_send_instructions_rejects_unaligned_play(self):
        class FakeSocket:
            def settimeout(self, timeout_s):
                pass

            def close(self):
                pass

        with mock.patch.object(host.socket, "socket", return_value=FakeSocket()):
            ctrl = host.RFSocController("192.168.1.128", transport="udp")
            with self.assertRaisesRegex(ValueError, "PLAY length must be 32B aligned"):
                ctrl.send_instructions([[2, 1, 33, host.tiled_channel_base_addr(1), host.PLAY_FLAG_TILED]])
            with self.assertRaisesRegex(ValueError, "PLAY addr must be 32B aligned"):
                ctrl.send_instructions([[2, 1, host.FIXED_DATA_BYTES, 8, host.PLAY_FLAG_TILED]])
            ctrl.close()



if __name__ == "__main__":
    unittest.main()
