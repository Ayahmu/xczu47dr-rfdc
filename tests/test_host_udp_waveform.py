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
        self.assertEqual(host.DAC_XY_FS, 1_000_000_000.0)

    def test_default_ddr_addresses_match_bd_mapped_base(self):
        self.assertEqual(host.DDR_BASE, 0x0000000000000000)
        self.assertEqual(host.DDR_CH1_ADDR, 0x0000000000000000)
        self.assertEqual(host.DDR_CH2_ADDR, 0x0000000000001000)
        self.assertEqual(host.DDR_CH3_ADDR, 0x0000000000002000)
        self.assertEqual(host.DDR_CH4_ADDR, 0x0000000000003000)
        self.assertEqual(host.DDR_X_ADDR, host.DDR_CH1_ADDR)
        self.assertEqual(host.DDR_Y_ADDR, host.DDR_CH2_ADDR)

    def test_packets_are_128_bit_ddr_writes(self):
        samples = np.arange(8, dtype=np.int16)
        packets = list(host.iter_udp_waveform_packets(samples, host.DDR_X_ADDR, sample_count=8))

        self.assertEqual(len(packets), 1)
        self.assertEqual(len(packets[0]), 32)

        magic, addr, low, high = struct.unpack("<QQQQ", packets[0])
        self.assertEqual(magic, host.UDP_WAVE_DDR_MAGIC)
        self.assertEqual(addr, 0x0000000000000000)

        payload = struct.pack("<QQ", low, high)
        self.assertEqual(payload, samples.astype("<i2").tobytes())

    def test_short_waveform_is_zero_padded(self):
        samples = np.array([1, -1], dtype=np.int16)
        packets = list(host.iter_udp_waveform_packets(samples, host.DDR_Y_ADDR, sample_count=8))

        _, addr, low, high = struct.unpack("<QQQQ", packets[0])
        payload = struct.pack("<QQ", low, high)
        decoded = np.frombuffer(payload, dtype="<i2")

        self.assertEqual(addr, 0x0000000000001000)
        np.testing.assert_array_equal(decoded, np.array([1, -1, 0, 0, 0, 0, 0, 0], dtype=np.int16))

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



if __name__ == "__main__":
    unittest.main()
