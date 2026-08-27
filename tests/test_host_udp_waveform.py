import struct
import sys
import tempfile
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
        self.assertEqual(host.DAC_TILE_FS, 6_400_000_000.0)
        self.assertEqual(host.DAC_IQ_SAMPLE_RATE_HZ, 400_000_000.0)
        self.assertEqual(host.DAC_FABRIC_HZ, 50_000_000.0)
        self.assertEqual(host.RFDC_INTERPOLATION, 16)
        self.assertEqual(host.DEFAULT_DDR_LAYOUT, host.DDR_LAYOUT_INTERLEAVED_512B)
        self.assertEqual(host.CHANNEL_ROLES[5], "z")
        self.assertEqual(host.CHANNEL_ROLES[7], "readout")
        self.assertEqual(host.DEFAULT_READOUT_TARGET_RF_HZ[8], 6.2e9)

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

    def test_extreme_length_capacity_matches_8gib_ddr_with_top_reserve(self):
        self.assertEqual(host.DDR_PHYS_BYTES, 0x200000000)
        self.assertEqual(host.DDR_RESERVED_TOP_BYTES, 0x100000)
        self.assertEqual(host.DDR_USABLE_WAVEFORM_BYTES, 0x1FFF00000)
        self.assertEqual(host.DDR_MAX_BYTES_PER_CHANNEL, 0x3FFE0000)
        self.assertEqual(host.DDR_MAX_INTERLEAVED_BYTES, 0x1FFF00000)
        self.assertEqual(host.RFDC_CTRL_MAILBOX_OFFSET, 0x1FFF00000)
        self.assertEqual(host.DDR_MAX_BYTES_PER_CHANNEL // host.BEAT_BYTES, 33_550_336)
        self.assertAlmostEqual(
            host.DDR_MAX_BYTES_PER_CHANNEL / (host.DAC_FABRIC_HZ * host.BEAT_BYTES),
            0.67100672,
        )

    def test_tiled_ddr_address_mapping(self):
        self.assertEqual(host.tiled_ddr_addr(1, 0), host.DDR_BASE)
        self.assertEqual(host.tiled_ddr_addr(2, 0), host.DDR_BASE + host.DDR_TILE_BYTES)
        self.assertEqual(host.tiled_ddr_addr(1, host.DDR_TILE_BYTES), host.DDR_BASE + host.DDR_SUPERBLOCK_BYTES)
        self.assertEqual(host.tiled_ddr_addr(8, 32), host.DDR_BASE + 7 * host.DDR_TILE_BYTES + 32)

    def test_tiled_ddr_address_requires_32_byte_alignment(self):
        with self.assertRaisesRegex(ValueError, "byte_offset must be 32B aligned"):
            host.tiled_ddr_addr(1, 2)

    def test_interleaved_ddr_lane_address_mapping(self):
        self.assertEqual(host.interleaved_ddr_addr(1, 0), host.DDR_BASE)
        self.assertEqual(host.interleaved_ddr_addr(2, 0), host.DDR_BASE + 8)
        self.assertEqual(host.interleaved_ddr_addr(8, 0), host.DDR_BASE + 56)
        self.assertEqual(host.interleaved_ddr_addr(1, 8), host.DDR_BASE + 64)
        self.assertEqual(host.interleaved_ddr_addr(3, 16), host.DDR_BASE + 128 + 16)

    def test_interleaved_packer_lane_order(self):
        channel_waves = {
            channel: np.array([
                channel * 100 + 0,
                channel * 100 + 1,
                channel * 100 + 2,
                channel * 100 + 3,
                channel * 100 + 4,
                channel * 100 + 5,
                channel * 100 + 6,
                channel * 100 + 7,
            ], dtype=np.int16)
            for channel in range(1, 9)
        }

        payload, logical_samples = host.pack_interleaved_512b_waveforms(channel_waves)

        self.assertEqual(logical_samples, 16)
        self.assertEqual(len(payload), 256)
        first_beat = payload[:64]
        lanes = [np.frombuffer(first_beat[idx * 8:(idx + 1) * 8], dtype="<i2").tolist() for idx in range(8)]
        self.assertEqual(lanes[0], [100, 101, 102, 103])
        self.assertEqual(lanes[1], [200, 201, 202, 203])
        self.assertEqual(lanes[7], [800, 801, 802, 803])

    def test_max_length_bulk_stream_preserves_marker_lane_order_and_addresses(self):
        bytes_per_channel = 16 * 1024
        datagrams = list(host.iter_max_length_udp_batches(
            bytes_per_channel,
            beats_per_datagram=host.UDP_BULK_SAFE_MAX_BEATS,
            marker_bytes_per_channel=4096,
            pattern=host.MAX_LENGTH_PATTERN_CW_MARKER,
        ))
        decoded = [host.decode_udp_bulk_datagram(datagram) for datagram in datagrams]
        self.assertEqual(decoded[0][0], host.DDR_BASE)
        self.assertEqual(decoded[-1][0] + len(decoded[-1][1]), host.DDR_BASE + bytes_per_channel * 8)

        payload = b"".join(data for _addr, data in decoded)
        total_beats = len(payload) // 64
        for beat_index, region in ((0, "start"), (total_beats // 2, "middle"), (total_beats - 1, "end")):
            beat = payload[beat_index * 64:(beat_index + 1) * 64]
            lanes = [np.frombuffer(beat[ch * 8:(ch + 1) * 8], dtype="<i2").tolist() for ch in range(8)]
            for channel, lane in enumerate(lanes, start=1):
                amplitude = host.max_length_marker_amplitude(channel, region)
                self.assertEqual(lane, [amplitude, 0, amplitude, 0])

    def test_max_length_lowfreq_sine_stream_uses_i_only_lanes(self):
        datagram = next(host.iter_max_length_udp_batches(
            4096,
            beats_per_datagram=4,
            pattern=host.MAX_LENGTH_PATTERN_LOWFREQ_SINE,
            sine_freq_hz=10_000_000.0,
            sine_amplitude=4096,
        ))
        _addr, payload = host.decode_udp_bulk_datagram(datagram)

        first_beat = payload[:64]
        lanes = [np.frombuffer(first_beat[ch * 8:(ch + 1) * 8], dtype="<i2").tolist() for ch in range(8)]

        self.assertTrue(any(lane[0] != 0 or lane[2] != 0 for lane in lanes))
        self.assertTrue(all(lane[1] == 0 and lane[3] == 0 for lane in lanes))
        self.assertNotEqual(lanes[0], lanes[2])

    def test_max_length_waveform_cache_reuses_raw_payload(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            cache_path = host.ensure_max_length_waveform_cache(
                temp_dir,
                4096,
                pattern=host.MAX_LENGTH_PATTERN_LOWFREQ_SINE,
                sine_freq_hz=10_000_000.0,
                sine_amplitude=4096,
                generation_chunk_beats=4,
            )
            self.assertEqual(cache_path.stat().st_size, 4096 * 8)
            second_path = host.ensure_max_length_waveform_cache(
                temp_dir,
                4096,
                pattern=host.MAX_LENGTH_PATTERN_LOWFREQ_SINE,
                sine_freq_hz=10_000_000.0,
                sine_amplitude=4096,
            )
            self.assertEqual(second_path, cache_path)

            datagram = next(host.iter_max_length_udp_batches_from_cache(cache_path, 4096, beats_per_datagram=4))
            _addr, payload = host.decode_udp_bulk_datagram(datagram)
            lanes = [np.frombuffer(payload[ch * 8:(ch + 1) * 8], dtype="<i2").tolist() for ch in range(8)]
            self.assertTrue(any(lane[0] != 0 or lane[2] != 0 for lane in lanes))
            self.assertTrue(all(lane[1] == 0 and lane[3] == 0 for lane in lanes))

    def test_max_length_bulk_stream_rejects_over_capacity(self):
        with self.assertRaisesRegex(ValueError, "bytes_per_channel"):
            next(host.iter_max_length_udp_batches(host.DDR_MAX_BYTES_PER_CHANNEL + 32))

    def test_max_length_bulk_stream_rejects_packets_larger_than_pl_limit(self):
        with self.assertRaisesRegex(ValueError, "PL UDP bulk parser limit"):
            next(host.iter_max_length_udp_batches(4096, beats_per_datagram=host.UDP_BULK_SAFE_MAX_BEATS + 1))

    def test_rfdc_nco_plan_maps_zone1_and_zone2_targets(self):
        self.assertEqual(host.rfdc_nco_plan_for_target(3.5e9)["nco_hz"], -2.9e9)
        self.assertEqual(host.rfdc_nco_plan_for_target(3.5e9)["nyquist_zone"], 2)
        self.assertEqual(host.rfdc_nco_plan_for_target(4.5e9)["nco_hz"], -1.9e9)
        self.assertEqual(host.rfdc_nco_plan_for_target(4.5e9)["nyquist_zone"], 2)
        self.assertEqual(host.rfdc_nco_plan_for_target(5.5e9)["nco_hz"], -0.9e9)
        self.assertEqual(host.rfdc_nco_plan_for_target(5.5e9)["nyquist_zone"], 2)
        self.assertEqual(host.rfdc_nco_plan_for_target(6.2e9)["nco_hz"], -0.2e9)
        self.assertEqual(host.rfdc_nco_plan_for_target(6.2e9)["nyquist_zone"], 2)
        with self.assertRaisesRegex(ValueError, "target RF frequency"):
            host.rfdc_nco_plan_for_target(6.5e9)

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

    def test_udp_controller_reports_missing_cap_net_raw_for_interface_binding(self):
        class FakeSocket:
            def settimeout(self, timeout_s):
                pass

            def setsockopt(self, level, optname, value):
                if optname == host.SO_BINDTODEVICE:
                    raise OSError(1, "Operation not permitted")

            def close(self):
                pass

        with mock.patch.object(host.socket, "socket", return_value=FakeSocket()):
            with self.assertRaisesRegex(PermissionError, "CAP_NET_RAW"):
                host.RFSocController(
                    "192.168.1.128",
                    transport="udp",
                    udp_interface="enp225s0f0",
                )

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
        magic, word_count = struct.unpack("<QQ", packet[:16])
        word0, word1, word2, word3 = struct.unpack("<IIII", packet[16:32])
        self.assertEqual(magic, host.UDP_WAVE_INSTR_MAGIC)
        self.assertEqual(word_count, 2)
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
        magic, word_count = struct.unpack("<QQ", packet[:16])
        word0, word1, word2, word3 = struct.unpack("<IIII", packet[16:32])
        self.assertEqual(magic, host.UDP_WAVE_INSTR_MAGIC)
        self.assertEqual(word_count, 2)
        self.assertEqual(word0, 0x00000212)
        self.assertEqual(word1, host.FIXED_DATA_BYTES)
        self.assertEqual(word2, host.tiled_channel_base_addr(1))
        self.assertEqual(word3, 0)

    def test_send_instructions_encodes_interleaved_play_flag_without_tiled_conflict(self):
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
            ctrl.send_instructions([[2, 1, host.FIXED_DATA_BYTES, 0, host.PLAY_FLAG_INTERLEAVED]])
            ctrl.close()

        packet = [call for call in fake_socket.calls if call[0] == "sendto"][0][1]
        magic, word_count = struct.unpack("<QQ", packet[:16])
        word0, word1, word2, word3 = struct.unpack("<IIII", packet[16:32])
        self.assertEqual(magic, host.UDP_WAVE_INSTR_MAGIC)
        self.assertEqual(word_count, 2)
        self.assertEqual(word0, 0x00000412)
        self.assertFalse(word0 & 0x00000200)
        self.assertEqual(word1, host.FIXED_DATA_BYTES)
        self.assertEqual(word2, 0)
        self.assertEqual(word3, 0)

    def test_udp_trigger_sends_single_reserved_word(self):
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
            ctrl.trigger()
            ctrl.close()

        packet = [call for call in fake_socket.calls if call[0] == "sendto"][0][1]
        self.assertEqual(packet, struct.pack("<Q", host.UDP_TRIGGER_WORD))

    def test_rvctrl_packet_packs_magic_count_and_padding(self):
        packet = host.pack_rvctrl_packet([host.RV_CMD_PING, 0x12345678, 0xA5A5A5A5])
        magic, word_count = struct.unpack("<QQ", packet[:16])
        payload = struct.unpack("<IIII", packet[16:32])

        self.assertEqual(magic, host.UDP_RVCTRL_MAGIC)
        self.assertEqual(word_count, 3)
        self.assertEqual(payload, (host.RV_CMD_PING, 0x12345678, 0xA5A5A5A5, 0))

    def test_rvctrl_play_interleaved_packs_control_flags(self):
        packet = host.pack_rvctrl_play_interleaved(
            4096,
            seq=9,
            auto_start=False,
            loop=True,
        )
        magic, word_count = struct.unpack("<QQ", packet[:16])
        cmd, seq, bytes_per_channel, flags = struct.unpack("<IIII", packet[16:32])

        self.assertEqual(magic, host.UDP_RVCTRL_MAGIC)
        self.assertEqual(word_count, 4)
        self.assertEqual(cmd, host.RV_CMD_PLAY_INTERLEAVED)
        self.assertEqual(seq, 9)
        self.assertEqual(bytes_per_channel, 4096)
        self.assertEqual(flags, host.RV_PLAY_FLAG_LOOP)

    def test_rvctrl1_mmio_write_packs_header_and_payload(self):
        packet = host.pack_rvctrl1_mmio_write32(0x120, 0xCAFE1234, seq=0x77)
        magic, hdr0, hdr1 = struct.unpack("<QQQ", packet[:24])
        addr, value = struct.unpack("<II", packet[24:32])

        self.assertEqual(magic, host.UDP_RVCTRL1_MAGIC)
        self.assertEqual(hdr0 & 0xFFFF, host.RVCTRL1_VERSION)
        self.assertEqual((hdr0 >> 16) & 0xFFFF, 0)
        self.assertEqual((hdr0 >> 32) & 0xFFFFFFFF, host.RV1_OP_MMIO_WRITE32)
        self.assertEqual(hdr1 & 0xFFFFFFFF, 0x77)
        self.assertEqual((hdr1 >> 32) & 0xFFFFFFFF, 8)
        self.assertEqual(addr, 0x120)
        self.assertEqual(value, 0xCAFE1234)

    def test_rvctrl1_batch_packs_counted_writes(self):
        packet = host.pack_rvctrl1_mmio_batch([(0x10, 0x11), (0x20, 0x22)], seq=3)
        magic, hdr0, hdr1 = struct.unpack("<QQQ", packet[:24])
        count, addr0, value0, addr1, value1 = struct.unpack("<IIIII", packet[24:44])

        self.assertEqual(magic, host.UDP_RVCTRL1_MAGIC)
        self.assertEqual((hdr0 >> 32) & 0xFFFFFFFF, host.RV1_OP_MMIO_BATCH)
        self.assertEqual(hdr1 & 0xFFFFFFFF, 3)
        self.assertEqual((hdr1 >> 32) & 0xFFFFFFFF, 20)
        self.assertEqual((count, addr0, value0, addr1, value1), (2, 0x10, 0x11, 0x20, 0x22))

    def test_rvctrl1_rfdc_set_nco_packs_channel_entries(self):
        packet = host.pack_rvctrl1_rfdc_set_nco({1: -1.9e9}, {1: 2}, seq=5, apply_mask=0x01)
        magic, hdr0, hdr1 = struct.unpack("<QQQ", packet[:24])
        apply_mask, ch1_nco, ch1_zone, _ = struct.unpack("<IqII", packet[24:44])

        self.assertEqual(magic, host.UDP_RVCTRL1_MAGIC)
        self.assertEqual((hdr0 >> 32) & 0xFFFFFFFF, host.RV1_OP_RFDC_SET_NCO)
        self.assertEqual(hdr1 & 0xFFFFFFFF, 5)
        self.assertEqual(apply_mask, 0x01)
        self.assertEqual(ch1_nco, -1900000000)
        self.assertEqual(ch1_zone, 2)

    def test_rvresp1_parser(self):
        payload = struct.pack("<I", 0xCAFE1234)
        hdr0 = (host.RV1_OP_MMIO_READ32 << 32) | (0 << 16) | host.RVCTRL1_VERSION
        hdr1 = (len(payload) << 32) | 0x44
        parsed = host.parse_rvresp1_packet(struct.pack("<QQQ", host.UDP_RVRESP1_MAGIC, hdr0, hdr1) + payload)

        self.assertEqual(parsed["version"], host.RVCTRL1_VERSION)
        self.assertEqual(parsed["status"], 0)
        self.assertEqual(parsed["opcode"], host.RV1_OP_MMIO_READ32)
        self.assertEqual(parsed["seq"], 0x44)
        self.assertEqual(parsed["payload"], payload)

    def test_rvresp1_receiver_filters_source_address(self):
        payload = b""
        hdr0 = (host.RV1_OP_PING << 32) | host.RVCTRL1_VERSION
        hdr1 = (len(payload) << 32) | 0x55
        packet = struct.pack("<QQQ", host.UDP_RVRESP1_MAGIC, hdr0, hdr1)

        class FakeSocket:
            def __init__(self):
                self.replies = [
                    (packet, ("192.168.1.200", 1234)),
                    (packet, ("192.168.1.128", 1234)),
                ]

            def settimeout(self, _timeout_s):
                pass

            def recvfrom(self, _size):
                return self.replies.pop(0)

            def close(self):
                pass

        with mock.patch.object(host.socket, "socket", return_value=FakeSocket()):
            ctrl = host.RFSocController("192.168.1.128", transport="udp")
            response = ctrl.recv_rvresp1(expected_seq=0x55, expected_opcode=host.RV1_OP_PING)
            ctrl.close()

        self.assertEqual(response["addr"], ("192.168.1.128", 1234))

    def test_rfdc_nco_mailbox_packs_entries_and_commits_header_last(self):
        nco = {channel: 4.5e9 for channel in range(1, 5)}
        nco.update({5: 0.0, 6: 0.0, 7: -0.6e9, 8: -0.2e9})
        zones = {channel: 2 for channel in range(1, 5)}
        zones.update({5: 1, 6: 1, 7: 2, 8: 2})

        image = host.pack_rfdc_nco_mailbox(nco, zones, seq=7)
        magic, seq, mask, flags, _ = struct.unpack("<QIII12s", image[:host.RFDC_CTRL_MAILBOX_HEADER_BYTES])
        ch5_nco_hz, ch5_zone, _ = struct.unpack(
            "<qII",
            image[host.RFDC_CTRL_MAILBOX_HEADER_BYTES + 4 * host.RFDC_CTRL_MAILBOX_ENTRY_BYTES:
                  host.RFDC_CTRL_MAILBOX_HEADER_BYTES + 5 * host.RFDC_CTRL_MAILBOX_ENTRY_BYTES],
        )

        self.assertEqual(len(image), host.RFDC_CTRL_MAILBOX_BYTES)
        self.assertEqual(magic, host.RFDC_CTRL_MAILBOX_MAGIC)
        self.assertEqual(seq, 7)
        self.assertEqual(mask, 0xFF)
        self.assertEqual(flags, host.RFDC_CTRL_MAILBOX_FLAG_APPLY_IMMEDIATE)
        self.assertEqual(ch5_nco_hz, 0)
        self.assertEqual(ch5_zone, 1)

        packets = list(host.iter_rfdc_nco_mailbox_packets(nco, zones, seq=7))
        self.assertEqual(len(packets), 5)
        _, first_addr, _ = host.decode_udp_waveform_packet(packets[0])
        _, last_addr, last_payload = host.decode_udp_waveform_packet(packets[-1])
        self.assertEqual(first_addr, host.RFDC_CTRL_MAILBOX_OFFSET + host.RFDC_CTRL_MAILBOX_HEADER_BYTES)
        self.assertEqual(last_addr, host.RFDC_CTRL_MAILBOX_OFFSET)
        self.assertEqual(last_payload, image[:host.RFDC_CTRL_MAILBOX_HEADER_BYTES])

    def test_rfdc_runtime_mailbox_preserves_negative_phase_and_fractional_current(self):
        image = host.pack_rfdc_runtime_mailbox(
            {1: -1.9e9},
            {1: 2},
            {1: -90.5},
            {1: 40.5},
            seq=9,
            apply_mask=0x01,
        )
        entry = image[
            host.RFDC_RUNTIME_MAILBOX_HEADER_BYTES:
            host.RFDC_RUNTIME_MAILBOX_HEADER_BYTES + host.RFDC_RUNTIME_MAILBOX_ENTRY_BYTES
        ]
        nco_hz, zone, phase_mdeg, current_ua, *_ = struct.unpack("<qIiIIII", entry)

        self.assertEqual(nco_hz, -1_900_000_000)
        self.assertEqual(zone, 2)
        self.assertEqual(phase_mdeg, -90_500)
        self.assertEqual(current_ua, 40_500)

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

    def test_rfctrl2_packets_are_versioned_and_round_trip(self):
        packet = host.pack_rfctrl2_arm(run_id=0xCAFE, channel_mask=0x3F, seq=0x77)
        magic, hdr0, hdr1, run_id, channel_mask = struct.unpack("<QQQII", packet)
        self.assertEqual(magic, host.UDP_RFCTRL2_MAGIC)
        self.assertEqual(hdr0 & 0xFFFF, host.RFCTRL2_VERSION)
        self.assertEqual(hdr0 >> 32, host.RF2_OP_ARM)
        self.assertEqual(hdr1 & 0xFFFFFFFF, 0x77)
        self.assertEqual(hdr1 >> 32, 8)
        self.assertEqual(run_id, 0xCAFE)
        self.assertEqual(channel_mask, 0x3F)

        payload = struct.pack("<QQ", 0x1234, 0x5678)
        response_hdr0 = (host.RF2_OP_STATUS << 32) | host.RFCTRL2_VERSION
        response_hdr1 = (len(payload) << 32) | 0x77
        parsed = host.parse_rfresp2_packet(struct.pack("<QQQ", host.UDP_RFRESP2_MAGIC, response_hdr0, response_hdr1) + payload)
        self.assertEqual(parsed["version"], host.RFCTRL2_VERSION)
        self.assertEqual(parsed["opcode"], host.RF2_OP_STATUS)
        self.assertEqual(parsed["seq"], 0x77)
        self.assertEqual(parsed["payload"], payload)

    def test_rfctrl2_controller_sends_scheduled_start(self):
        class FakeSocket:
            def __init__(self):
                self.calls = []

            def settimeout(self, timeout_s):
                self.calls.append(("settimeout", timeout_s))

            def sendto(self, packet, addr):
                self.calls.append(("sendto", packet, addr))
                return len(packet)

            def close(self):
                self.calls.append(("close",))

        fake_socket = FakeSocket()
        with mock.patch.object(host.socket, "socket", return_value=fake_socket):
            ctrl = host.RFSocController("192.168.1.129", transport="udp")
            sent = ctrl.rfctrl2_start_at(5_000_000, seq=9, wait_response=False)
            ctrl.close()

        self.assertGreater(sent, 0)
        packet = next(call[1] for call in fake_socket.calls if call[0] == "sendto")
        magic, hdr0, hdr1, start_tick = struct.unpack("<QQQQ", packet)
        self.assertEqual(magic, host.UDP_RFCTRL2_MAGIC)
        self.assertEqual(hdr0 >> 32, host.RF2_OP_START_AT)
        self.assertEqual(hdr1 & 0xFFFFFFFF, 9)
        self.assertEqual(start_tick, 5_000_000)



if __name__ == "__main__":
    unittest.main()
