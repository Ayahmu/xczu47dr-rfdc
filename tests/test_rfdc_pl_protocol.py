import socket
import struct
import unittest
from unittest.mock import patch

from software import host


def channel_maps():
    nco = {channel: (-1_900_000_000 if channel <= 4 else 0) for channel in range(1, 9)}
    zones = {channel: (2 if channel <= 4 else 1) for channel in range(1, 9)}
    phases = {channel: 450.0 + channel for channel in range(1, 9)}
    currents = {channel: (20.0 if channel not in (5, 6) else 6.4) for channel in range(1, 9)}
    return nco, zones, phases, currents


class RfdcPlProtocolTests(unittest.TestCase):
    def test_apply_packet_has_fixed_eight_channel_layout(self):
        nco, zones, phases, currents = channel_maps()
        packet = host.pack_rfctrl2_rfdc_apply(
            nco, zones, phases, currents, revision=7, channel_mask=0x31, seq=19
        )
        magic, hdr0, hdr1 = struct.unpack_from("<QQQ", packet)
        self.assertEqual(magic, host.UDP_RFCTRL2_MAGIC)
        self.assertEqual(hdr0 >> 32, host.RF2_OP_RFDC_APPLY)
        self.assertEqual(hdr1 & 0xFFFFFFFF, 19)
        self.assertEqual(hdr1 >> 32, 200)
        revision, mask = struct.unpack_from("<II", packet, 24)
        self.assertEqual((revision, mask), (7, 0x31))
        ch1 = struct.unpack_from("<qIiII", packet, 32)
        self.assertEqual(ch1[:2], (-1_900_000_000, 2))
        self.assertEqual(ch1[2], 91_000)
        self.assertEqual(ch1[3], 20_000)

    def test_phase_is_normalized_and_dc_current_range_is_enforced(self):
        nco, zones, phases, currents = channel_maps()
        packet = host.pack_rfctrl2_rfdc_apply(nco, zones, phases, currents, revision=1)
        ch1 = struct.unpack_from("<qIiII", packet, 32)
        self.assertEqual(ch1[2], 91_000)
        currents[5] = 2.25
        with self.assertRaisesRegex(ValueError, "CH5 DC-coupled"):
            host.pack_rfctrl2_rfdc_apply(nco, zones, phases, currents, revision=2)

    def test_hardware_response_decodes_masks_and_raw_register_values(self):
        header = struct.pack("<IIIIIIII", 9, 0x0F, 0x10, 0xEF, 8, 0x1CC, 2, 1)
        entries = b"".join(
            struct.pack(
                "<qIiIIQII",
                channel * 1_000_000,
                1,
                channel * 1000,
                20_000,
                0 if channel != 5 else host.RF2_STATUS_READBACK,
                channel,
                channel + 10,
                channel + 20,
            )
            for channel in range(1, 9)
        )
        payload = header + entries
        hdr0 = (host.RF2_OP_RFDC_APPLY << 32) | (host.RF2_STATUS_PARTIAL << 16) | host.RFCTRL2_VERSION
        packet = struct.pack(
            "<QQQ", host.UDP_RFRESP2_MAGIC, hdr0, (len(payload) << 32) | 22
        ) + payload
        decoded = host.parse_rfctrl2_rfdc_config_response(host.parse_rfresp2_packet(packet))
        self.assertEqual(decoded["applied_mask"], 0x0F)
        self.assertEqual(decoded["error_mask"], 0x10)
        self.assertEqual(decoded["failure_address"], 0x1CC)
        self.assertEqual(decoded["channels"][4]["status"], host.RF2_STATUS_READBACK)
        self.assertEqual(decoded["channels"][0]["nco_word"], 1)

    def test_timeout_retry_reuses_identical_packet_and_sequence(self):
        nco, zones, phases, currents = channel_maps()

        class FakeSocket:
            def __init__(self, *_args, **_kwargs):
                self.sent = []
                self.receive_count = 0

            def settimeout(self, _timeout):
                pass

            def sendto(self, packet, address):
                self.sent.append((packet, address))
                return len(packet)

            def recvfrom(self, _size):
                self.receive_count += 1
                if self.receive_count == 1:
                    raise socket.timeout()
                payload = struct.pack("<IIIIIIII", 3, 0xFF, 0, 0xFF, 0, 0, 0, 1)
                payload += b"".join(
                    struct.pack("<qIiIIQII", 0, 1, 0, 20_000, 0, 0, 0, 425)
                    for _ in range(8)
                )
                hdr0 = (host.RF2_OP_RFDC_APPLY << 32) | host.RFCTRL2_VERSION
                return (
                    struct.pack("<QQQ", host.UDP_RFRESP2_MAGIC, hdr0, (len(payload) << 32) | 77) + payload,
                    ("192.168.1.128", 1234),
                )

            def close(self):
                pass

        fake = FakeSocket()
        with patch.object(host.socket, "socket", return_value=fake):
            controller = host.RFSocController("192.168.1.128", timeout_s=0.01)
            result = controller.rfctrl2_rfdc_apply(
                nco, zones, phases, currents, revision=3, seq=77, retries=1
            )
        self.assertEqual(result["status"], host.RF2_STATUS_OK)
        self.assertEqual(len(fake.sent), 2)
        self.assertEqual(fake.sent[0][0], fake.sent[1][0])


if __name__ == "__main__":
    unittest.main()
