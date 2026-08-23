import socket
import struct
import sys
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "software"))

from dr47 import (  # noqa: E402
    Dr47Device,
    RFDC_NCO_MAX_GHZ,
    RFDC_NCO_MIN_GHZ,
    SequenceGenerator,
    SimulatedDr47Device,
    TriggerSeqGenerate,
    UnsupportedCapabilityError,
    UDP_RFCTRL2_MAGIC,
    UDP_RFRESP2_MAGIC,
    RF2_OP_STATUS,
    RFCTRL2_VERSION,
    pack_rfctrl2_arm,
    pack_interleaved_512b_waveforms,
    rfdc_nco_plan_for_target,
    DiscoveredBoard,
    parse_ip_pool,
)
from dr47.hardware_wave_test import (  # noqa: E402
    EXAMPLES,
    make_gaussian_iq_sine,
    make_iq_sine,
    make_trigger_sequence,
    sample_count_for_duration,
)
from dr47.transport import UdpTransport  # noqa: E402


class _RetrySocket:
    def __init__(self):
        self.sent = []
        self.receives = 0

    def settimeout(self, _timeout):
        pass

    def setsockopt(self, *_args):
        pass

    def sendto(self, packet, addr):
        self.sent.append((bytes(packet), addr))
        return len(packet)

    def recvfrom(self, _size):
        self.receives += 1
        if self.receives == 1:
            raise socket.timeout()
        request = self.sent[-1][0]
        _magic, _hdr0, hdr1 = struct.unpack("<QQQ", request[:24])
        seq = hdr1 & 0xFFFFFFFF
        packet = struct.pack(
            "<QQQ", UDP_RFRESP2_MAGIC,
            (RF2_OP_STATUS << 32) | RFCTRL2_VERSION,
            seq,
        )
        return packet, ("192.168.1.128", 1234)

    def close(self):
        pass


class _BroadcastSocket:
    def __init__(self, packets):
        self.packets = list(packets)
        self.sent = []
        self.timeout = None

    def settimeout(self, value):
        self.timeout = value

    def setsockopt(self, *_args):
        pass

    def sendto(self, packet, addr):
        self.sent.append((bytes(packet), addr))
        return len(packet)

    def recvfrom(self, _size):
        if self.packets:
            return self.packets.pop(0)
        raise socket.timeout()

    def close(self):
        pass


class DriverTests(unittest.TestCase):
    def test_rfctrl2_bytes_match_little_endian_contract(self):
        packet = pack_rfctrl2_arm(0xCAFE, 0x3F, 0x77)
        magic, hdr0, hdr1, run_id, channel_mask = struct.unpack("<QQQII", packet)
        self.assertEqual(magic, UDP_RFCTRL2_MAGIC)
        self.assertEqual(hdr0 & 0xFFFF, RFCTRL2_VERSION)
        self.assertEqual(hdr0 >> 32, 6)
        self.assertEqual(hdr1 & 0xFFFFFFFF, 0x77)
        self.assertEqual((run_id, channel_mask), (0xCAFE, 0x3F))

    def test_transport_retries_immutable_packet_and_filters_sequence(self):
        sock = _RetrySocket()
        transport = UdpTransport("192.168.1.128", sock=sock, timeout_s=0.01)
        packet = struct.pack("<QQQ", UDP_RFCTRL2_MAGIC, (RF2_OP_STATUS << 32) | RFCTRL2_VERSION, 7)
        response = transport.request(packet, seq=7, opcode=RF2_OP_STATUS, retries=1)
        self.assertEqual(response["seq"], 7)
        self.assertEqual(len(sock.sent), 2)
        self.assertEqual(sock.sent[0][0], sock.sent[1][0])

    def test_transport_collects_all_broadcast_responses(self):
        from dr47.protocol import UDP_RFRESP2_MAGIC

        sequence = 17
        payload = struct.pack(
            "<QQQQQQQQ",
            0x47D001,
            0x78563412 | (0xFEA9 << 32),
            0x0000020000000001,
            1 | (1234 << 32),
            0x00040000,
            0x0000020000000001,
            0xFFFF0000,
            0,
        )
        response_packet = struct.pack(
            "<QQQ", UDP_RFRESP2_MAGIC, (0x0C << 32) | RFCTRL2_VERSION,
            (len(payload) << 32) | sequence,
        ) + payload
        packets = [
            (response_packet, ("169.254.1.2", 1234)),
            (response_packet, ("169.254.2.3", 1234)),
        ]
        sock = _BroadcastSocket(packets)
        transport = UdpTransport("169.254.255.255", sock=sock, timeout_s=0.01)
        responses = transport.receive_rfresp2_many(expected_seq=sequence, expected_opcode=0x0C, timeout_s=0.01)
        self.assertEqual([item["addr"][0] for item in responses], ["169.254.1.2", "169.254.2.3"])

    def test_ip_pool_parser_and_discovery_record(self):
        self.assertEqual(parse_ip_pool("10.50.0.101-10.50.0.103"), ["10.50.0.101", "10.50.0.102", "10.50.0.103"])
        board = DiscoveredBoard("uid", "169.254.1.2", "02:00:00:00:00:01")
        self.assertEqual(board.as_dict()["current_ip"], "169.254.1.2")

    def test_interleaved_layout_uses_ch1_to_ch8_lanes(self):
        image, samples = pack_interleaved_512b_waveforms({1: np.array([1, 2, 3, 4], dtype=np.int16), 2: np.array([5, 6, 7, 8], dtype=np.int16)})
        self.assertEqual(samples, 16)
        self.assertEqual(struct.unpack_from("<hhhh", image, 0), (1, 2, 3, 4))
        self.assertEqual(struct.unpack_from("<hhhh", image, 8), (5, 6, 7, 8))

    def test_simulator_state_machine_and_unsupported_capability(self):
        device = SimulatedDr47Device()
        device.connect()
        device.set_xy_nco_frequency(1, 0.1)
        device.set_qc_on_off("xy", 1, "on")
        device.upload_waveforms({1: np.array([1, 0, 2, 0], dtype=np.int16)}, wave_formats={1: "interleaved_iq"})
        device.arm()
        self.assertEqual(device.status(refresh=False).state.value, "armed")
        device.trigger()
        self.assertEqual(device.status(refresh=False).state.value, "running")
        device.abort_mute()
        self.assertEqual(device.status(refresh=False).state.value, "idle")
        with self.assertRaises(UnsupportedCapabilityError):
            device.get_daq_data(1)

    def test_simulator_self_test_models_xs18_to_xs19_loopback(self):
        device = SimulatedDr47Device(batch_mode=True)
        device.connect()
        device.set_sync_role("slave")
        device.set_sync_mode("self_test")
        device.set_xy_nco_frequency(1, 1.0)
        device.apply_rfdc_config(channel_mask=0x01)
        device.set_qc_on_off("xy", 1, "on")
        device.upload_waveforms(
            {1: np.array([1200, 0, 1200, 0], dtype=np.int16)},
            wave_formats={1: "interleaved_iq"},
        )
        device.arm(channel_mask=0x01)
        device.emit_trigger()
        status = device.status(refresh=False)
        self.assertTrue(status.capabilities.sync_link_ready)
        self.assertEqual(status.capabilities.trigger_input_count, 1)
        self.assertEqual(status.capabilities.trigger_accepted_count, 1)
        self.assertEqual(status.capabilities.trigger_output_count, 1)
        self.assertEqual(status.state, status.capabilities.playback_state)

    def test_negative_nco_preserves_explicit_nyquist_zone(self):
        device = SimulatedDr47Device(batch_mode=True)
        device.connect()
        device.apply_rfdc_config(nyquist_zone={1: 1}, channel_mask=0x01)
        device.set_xy_nco_frequency(1, -0.1)
        self.assertEqual(device._pending_zone[1], 1)

    def test_public_frequency_api_uses_ghz_and_converts_at_protocol_boundary(self):
        device = SimulatedDr47Device(batch_mode=True)
        device.connect()
        device.set_xy_nco_frequency(1, 1.79)
        self.assertEqual(device._pending_nco[1], 1_790_000_000.0)
        device.apply_rfdc_config(nco_ghz={1: -1.5}, channel_mask=0x01)
        self.assertEqual(device._pending_nco[1], -1_500_000_000.0)
        self.assertEqual(RFDC_NCO_MIN_GHZ, -3.2)
        self.assertEqual(RFDC_NCO_MAX_GHZ, 3.2)

    def test_public_target_plan_returns_ghz(self):
        self.assertEqual(rfdc_nco_plan_for_target(1.79), {
            "target_rf_ghz": 1.79,
            "nco_ghz": 1.79,
            "nyquist_zone": 1,
            "image": "direct",
        })
        zone2 = rfdc_nco_plan_for_target(4.5)
        self.assertEqual(zone2["nco_ghz"], -1.9)
        self.assertEqual(zone2["nyquist_zone"], 2)

    def test_wave_examples_use_ghz_ns_and_trigger_sequence(self):
        self.assertEqual(sample_count_for_duration(100.0, 0.4), 40)
        sine = make_iq_sine(100.0, 0.0, 0.4, 0.5)
        gaussian = make_gaussian_iq_sine(60.0, 0.0, 0.4, 0.5)
        self.assertEqual(sine.shape, (40, 2))
        self.assertEqual(gaussian.shape, (24, 2))
        self.assertLess(abs(int(gaussian[0, 0])), abs(int(gaussian[12, 0])))
        sequence = make_trigger_sequence(24)
        self.assertEqual(sequence.dtype, np.dtype("<u2"))
        self.assertEqual(sequence[1, 3] >> 11, 8)
        self.assertEqual(set(EXAMPLES), {
            "one_shot_1ghz_sine",
            "one_shot_1p79ghz_gaussian_xy",
            "continuous_2ghz_sine",
            "triggered_1p5ghz_gaussian_xy",
        })

    def test_sequence_generator_emits_trigger_delay_loop_and_stop(self):
        generator = SequenceGenerator("XY", time_data=[0.0], event_data=[np.array([1, 2], dtype=np.int32)], period=1e-6, repeat=1)
        wave, sequence = generator.TriggerSeqGenerate()
        self.assertEqual(wave.dtype, np.int32)
        self.assertEqual(sequence.shape[1], 4)
        funcs = ((sequence[:, 3] >> 11) & 0xF).tolist()
        self.assertIn(8, funcs)
        self.assertIn(1, funcs)
        self.assertTrue(bool(sequence[-1, 3] & 0x8000))
        functional_wave, functional_sequence = TriggerSeqGenerate(
            "XY", time_data=[0.0], event_data=[np.array([1, 2], dtype=np.int32)], period=1e-6, repeat=1
        )
        self.assertEqual(functional_wave.dtype, np.int32)
        self.assertEqual(functional_sequence.shape[1], 4)


if __name__ == "__main__":
    unittest.main()
