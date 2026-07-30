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
    def test_status_payload_reports_prepared_separately_from_armed(self):
        payload = struct.pack(
            "<IIIIIIII",
            host.RF2_CAP_PL_RFDC_CONFIG,
            host.RF2_STATUS_RFDC_READY | host.RF2_STATUS_ARMED | host.RF2_STATUS_PREPARED,
            0x31,
            7,
            0,
            0,
            0,
            0,
        )
        decoded = host.parse_rfctrl2_status_payload({"payload": payload})
        self.assertTrue(decoded["armed"])
        self.assertTrue(decoded["prepared"])
        self.assertFalse(decoded["running"])

    def test_extended_status_payload_reports_playback_debug(self):
        payload = struct.pack(
            "<IIIIIIIIQQQQ",
            host.RF2_CAP_PL_RFDC_CONFIG,
            host.RF2_STATUS_RFDC_READY | host.RF2_STATUS_ARMED,
            0x03,
            9,
            0,
            0,
            0,
            0,
            (0x02 << 32) | 0x03,
            (0x05 << 32) | 0x0F,
            (0x12 << 32) | 0x34,
            (1 << 33) | (1 << 32) | 1,
        )
        decoded = host.parse_rfctrl2_status_payload({"payload": payload})
        self.assertEqual(decoded["play_config_channel_mask"], 0x03)
        self.assertEqual(decoded["play_fifo_valid_mask"], 0x02)
        self.assertEqual(decoded["play_fifo_ready_mask"], 0x0F)
        self.assertEqual(decoded["play_executor_state"], 0x05)
        self.assertEqual(decoded["play_ddr_read_counter"], 0x34)
        self.assertEqual(decoded["play_bad_instr_count"], 0x12)
        self.assertTrue(decoded["play_prefill_ready"])
        self.assertTrue(decoded["play_pending_valid"])
        self.assertTrue(decoded["play_active_valid"])

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

    def test_network_apply_packet_and_response_round_trip(self):
        packet = host.pack_rfctrl2_network_apply(
            revision=12,
            ip="192.168.10.130",
            mac="02:00:00:00:00:42",
            subnet_mask="255.255.255.0",
            gateway="192.168.10.1",
            port=1234,
            seq=91,
        )
        magic, hdr0, hdr1 = struct.unpack_from("<QQQ", packet)
        self.assertEqual(magic, host.UDP_RFCTRL2_MAGIC)
        self.assertEqual(hdr0 >> 32, host.RF2_OP_NETWORK_APPLY)
        self.assertEqual(hdr1 & 0xFFFFFFFF, 91)
        self.assertEqual(hdr1 >> 32, host.NETWORK_APPLY_REQUEST_BYTES)
        revision, ip, mac, subnet, gateway, port, reserved, tail = struct.unpack_from(
            "<IIQIIHHI", packet, 24
        )
        self.assertEqual(revision, 12)
        self.assertEqual(ip, 0xC0A80A82)
        self.assertEqual(mac, 0x020000000042)
        self.assertEqual(subnet, 0xFFFFFF00)
        self.assertEqual(gateway, 0xC0A80A01)
        self.assertEqual(port, 1234)
        self.assertEqual((reserved, tail), (0, 0))

        payload = struct.pack(
            "<8Q",
            0x0000000047D00042,
            (0xC0A8FEFE << 32) | 0xC0A80A82,
            0x020000000042,
            (1 << 48) | (1234 << 32) | 12,
            (host.RF2_CAP_NETWORK_CONFIG << 0) | (1 << 32),
            0x020000000001,
            0xFFFFFF00,
            0xC0A80A01,
        )
        response_packet = (
            struct.pack(
                "<QQQ",
                host.UDP_RFRESP2_MAGIC,
                (host.RF2_OP_NETWORK_APPLY << 32) | host.RFCTRL2_VERSION,
                (len(payload) << 32) | 91,
            )
            + payload
        )
        decoded = host.parse_rfctrl2_network_response(host.parse_rfresp2_packet(response_packet))
        self.assertEqual(decoded["status"], host.RF2_STATUS_OK)
        self.assertEqual(decoded["device_uid"], "0000000047d00042")
        self.assertEqual(decoded["current_ip"], "192.168.10.130")
        self.assertEqual(decoded["bootstrap_ip"], "192.168.254.254")
        self.assertEqual(decoded["current_mac"], "02:00:00:00:00:42")
        self.assertEqual(decoded["revision"], 12)
        self.assertEqual(decoded["subnet_mask"], "255.255.255.0")
        self.assertEqual(decoded["gateway"], "192.168.10.1")

    def test_extended_network_response_reports_build_profile_and_playback_state(self):
        payload = struct.pack(
            "<10Q",
            0x0000000047D00042,
            (0xC0A8FEFE << 32) | 0xC0A80A82,
            0x020000000042,
            (1 << 48) | (1234 << 32) | 12,
            host.RF2_CAP_NETWORK_CONFIG | (host.RF2_STATUS_ARMED << 32),
            0x020000000001,
            0xFFFFFF00,
            0xC0A80A01,
            (host.RF2_STATUS_ARMED << 32) | host.RF2_BUILD_PROFILE_NORMAL,
            0x03,
        )
        response_packet = (
            struct.pack(
                "<QQQ",
                host.UDP_RFRESP2_MAGIC,
                (host.RF2_OP_NETWORK_GET << 32) | host.RFCTRL2_VERSION,
                (len(payload) << 32) | 92,
            )
            + payload
        )
        decoded = host.parse_rfctrl2_network_response(host.parse_rfresp2_packet(response_packet))
        self.assertEqual(decoded["build_profile"], "custom_xczu47dr")
        self.assertTrue(decoded["playback_armed"])
        self.assertEqual(decoded["rfdc_config_valid_mask"], 0x03)

    def test_network_apply_rejects_invalid_identity(self):
        with self.assertRaises(ValueError):
            host.pack_rfctrl2_network_apply(1, "192.168.10.999", "02:00:00:00:00:42")
        with self.assertRaises(ValueError):
            host.pack_rfctrl2_network_apply(1, "192.168.10.2", "01:00:00:00:00:42")
        with self.assertRaises(ValueError):
            host.pack_rfctrl2_network_apply(1, "192.168.10.2", "02:00:00:00:00:42", port=0)


if __name__ == "__main__":
    unittest.main()
