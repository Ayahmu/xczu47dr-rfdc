"""47DR 驱动协议、模拟器和波形上传契约的本地单元测试。

这些测试默认不访问真实板卡，也不需要 XS17/XS18/XS19/XS20 接线。它们使用
``SimulatedDr47Device`` 和假 UDP socket 验证：RFCTRL2 字节布局、重试与广播
收包、DNA 网络记录、主从同步门控、bypass 行为、NCO GHz 公共 API、波形记录
对齐以及与网页上传格式的 wire contract。通过本文件不能证明 HMC7044、RFDC
模拟 IP、FPGA 电气端口或最终 RF 频率/幅度已经在板上正常。
"""

import socket
import struct
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "software"))

# software/ has to be on sys.path first, so this import cannot move above the
# insert above - otherwise `python -m unittest tests.test_dr47_driver` from the
# repo root fails with ModuleNotFoundError: No module named 'host'.
import host  # type: ignore[import-not-found]  # noqa: E402

from dr47 import (  # noqa: E402
    Dr47Device,
    DeviceCapabilities,
    RFDC_NCO_MAX_GHZ,
    RFDC_NCO_MIN_GHZ,
    SimulatedDr47Device,
    make_trigger_sequence,
    make_single_trigger_sequence,
    SynchronizationError,
    DeviceStatusError,
    UDP_RFCTRL2_MAGIC,
    UDP_RFRESP2_MAGIC,
    RF2_OP_STATUS,
    RFCTRL2_VERSION,
    pack_rfctrl2_arm,
    pack_interleaved_512b_waveforms,
    rfdc_nco_plan_for_target,
    DiscoveredBoard,
    parse_ip_pool,
    iq_duration_to_interleaved_sample_count,
    make_iq_gaussian_sine_interleaved,
    make_iq_sine_interleaved,
    place_interleaved_iq_in_record,
)
from dr47.transport import UdpTransport  # noqa: E402
from dr47.errors import DriverError, TransportTimeout  # noqa: E402
import waveform_model  # noqa: E402
import waveform_tools  # noqa: E402
from dr47 import hardware_test_network  # noqa: E402


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


class _CaptureTransport:
    """Minimal write-only transport for exact upload packet comparison."""

    def __init__(self):
        self.sent: list[bytes] = []

    def send(self, packet: bytes) -> None:
        self.sent.append(bytes(packet))

    def close(self):
        pass


class _TransientHandshakeTransport:
    """首个握手请求超时、随后正常回复的最小板端模型。"""

    def __init__(self):
        self.requests: list[tuple[int, int]] = []
        self._first_request = True

    def request(self, _packet, *, seq, opcode, **_kwargs):
        self.requests.append((int(opcode), int(seq)))
        if self._first_request:
            self._first_request = False
            raise TransportTimeout("simulated initial RFRESP2 loss")
        return {
            "version": RFCTRL2_VERSION,
            "status": 0,
            "opcode": int(opcode),
            "seq": int(seq),
            "payload_bytes": 0,
            "payload": b"",
        }

    def close(self):
        pass


class DriverTests(unittest.TestCase):
    """按协议层、状态机层和波形层组织的驱动回归测试。"""

    def test_rfctrl2_bytes_match_little_endian_contract(self):
        """检查 ARM 包的魔数、版本、序号和通道掩码字节布局。"""
        packet = pack_rfctrl2_arm(0xCAFE, 0x3F, 0x77)
        magic, hdr0, hdr1, run_id, channel_mask = struct.unpack("<QQQII", packet)
        self.assertEqual(magic, UDP_RFCTRL2_MAGIC)
        self.assertEqual(hdr0 & 0xFFFF, RFCTRL2_VERSION)
        self.assertEqual(hdr0 >> 32, 6)
        self.assertEqual(hdr1 & 0xFFFFFFFF, 0x77)
        self.assertEqual((run_id, channel_mask), (0xCAFE, 0x3F))

    def test_transport_retries_immutable_packet_and_filters_sequence(self):
        """检查超时重试会复用同一请求包，并丢弃错误序号的响应。"""
        sock = _RetrySocket()
        transport = UdpTransport("192.168.1.128", sock=sock, timeout_s=0.01)
        packet = struct.pack("<QQQ", UDP_RFCTRL2_MAGIC, (RF2_OP_STATUS << 32) | RFCTRL2_VERSION, 7)
        response = transport.request(packet, seq=7, opcode=RF2_OP_STATUS, retries=1)
        self.assertEqual(response["seq"], 7)
        self.assertEqual(len(sock.sent), 2)
        self.assertEqual(sock.sent[0][0], sock.sent[1][0])

    @patch("software.dr47.transport.time.sleep")
    def test_transport_backoff_prevents_immediate_retry_collision(self, sleep_mock):
        """重试前应有短暂退避，避免撞上板端上一帧响应发送窗口。"""

        sock = _RetrySocket()
        transport = UdpTransport("192.168.1.128", sock=sock, timeout_s=0.01)
        packet = struct.pack("<QQQ", UDP_RFCTRL2_MAGIC, (RF2_OP_STATUS << 32) | RFCTRL2_VERSION, 7)
        transport.request(packet, seq=7, opcode=RF2_OP_STATUS, retries=1)
        sleep_mock.assert_called_once()
        self.assertGreaterEqual(float(sleep_mock.call_args.args[0]), 0.001)

    def test_connect_retries_the_entire_hello_status_handshake_after_transient_timeout(self):
        """首个 HELLO 漏回包时，connect 必须退避后重新开始完整握手。"""

        transport = _TransientHandshakeTransport()
        device = Dr47Device(
            ip="169.254.214.189",
            timeout_s=0.01,
            retries=0,
            transport=transport,
        )

        self.assertEqual(device.connect(), 0)
        self.assertTrue(device.connected)
        self.assertEqual([opcode for opcode, _ in transport.requests], [1, 1, RF2_OP_STATUS])

    def test_transport_collects_all_broadcast_responses(self):
        """检查一次广播请求可以收集不同板卡的多个响应源地址。"""
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
        """检查静态地址池展开，以及发现记录的字典字段。"""
        self.assertEqual(parse_ip_pool("10.50.0.101-10.50.0.103"), ["10.50.0.101", "10.50.0.102", "10.50.0.103"])
        board = DiscoveredBoard("uid", "169.254.1.2", "02:00:00:00:00:01")
        self.assertEqual(board.as_dict()["current_ip"], "169.254.1.2")

    def test_same_uid_boards_are_distinguished_by_mac(self):
        """交换机广播下 UID 重复时，MAC 仍能区分主卡和从卡。"""
        master = DiscoveredBoard(
            "same-uid", "169.254.32.1", "02:00:00:00:00:01",
        )
        slave = DiscoveredBoard(
            "same-uid", "169.254.32.1", "02:00:00:00:00:02",
        )
        roles = {
            master.identity_key: "master",
            slave.identity_key: "slave",
        }
        selected_master = hardware_test_network._select_board(
            [master, slave], roles,
            hardware_test_network.BoardNetworkAssignment("主卡", "master", "10.0.0.1"),
            set(),
        )
        selected_slave = hardware_test_network._select_board(
            [master, slave], roles,
            hardware_test_network.BoardNetworkAssignment("从卡", "slave", "10.0.0.2"),
            {selected_master.identity_key},
        )
        self.assertEqual(selected_master.current_mac, master.current_mac)
        self.assertEqual(selected_slave.current_mac, slave.current_mac)

    def test_shared_temporary_ip_is_rejected_before_provisioning(self):
        """两块板共用临时 IP 时，不能让 NETWORK_APPLY 随机命中目标。"""
        boards = [
            DiscoveredBoard(
                "same-uid", "169.254.32.1", "02:00:00:00:00:01",
                interface="enp-test", source_ip="169.254.250.11",
            ),
            DiscoveredBoard(
                "same-uid", "169.254.32.1", "02:00:00:00:00:02",
                interface="enp-test", source_ip="169.254.250.11",
            ),
        ]

        def connected(board, **_kwargs):
            device = MagicMock()
            role = "master" if board.current_mac.endswith("01") else "slave"
            device.status.return_value = SimpleNamespace(
                capabilities=SimpleNamespace(sync_role=role)
            )
            return device

        with (
            patch.object(hardware_test_network, "discover_boards", return_value=boards),
            patch.object(hardware_test_network, "connect_discovered", side_effect=connected),
            patch.object(hardware_test_network, "provision_board") as provision,
            self.assertRaisesRegex(DriverError, "共用临时地址"),
        ):
            hardware_test_network.discover_and_provision_boards(
                [
                    hardware_test_network.BoardNetworkAssignment("主卡", "master", "10.0.0.1"),
                    hardware_test_network.BoardNetworkAssignment("从卡", "slave", "10.0.0.2"),
                ],
                interface="enp-test",
                discovery_source_ip="169.254.250.11",
                discovery_source_cidr="169.254.250.11/16",
                control_source_ip="169.254.250.11",
            )
        provision.assert_not_called()

    def test_network_duplicate_check_excludes_board_being_provisioned(self):
        """同一板卡保留 DNA MAC、只改 IP 时不能被错误地判为 MAC 冲突。"""
        from dr47.network import ProvisionError, _check_duplicate_assignments

        target = DiscoveredBoard("target-uid", "169.254.32.1", "02:00:00:ad:15:91")
        other = DiscoveredBoard("other-uid", "169.254.32.2", "02:00:00:ad:15:92")
        _check_duplicate_assignments(
            [target, other],
            "169.254.100.102",
            target.current_mac,
            exclude_device_uid=target.device_uid,
        )
        with self.assertRaisesRegex(ProvisionError, "MAC .*other-uid"):
            _check_duplicate_assignments(
                [target, other],
                "169.254.100.102",
                other.current_mac,
                exclude_device_uid=target.device_uid,
            )
        with self.assertRaisesRegex(ProvisionError, "IP .*other-uid"):
            _check_duplicate_assignments(
                [target, other],
                other.current_ip,
                target.current_mac,
                exclude_device_uid=target.device_uid,
            )

    def test_hardware_test_network_discovers_roles_and_provisions_code_settings(self):
        """检查板级测试按角色选板，并使用代码常量完成 IP 配置和验证。"""

        master_board = DiscoveredBoard(
            "master-uid", "169.254.1.2", "02:00:00:00:00:01",
            interface="enp-test", source_ip="169.254.250.11",
        )
        slave_board = DiscoveredBoard(
            "slave-uid", "169.254.2.3", "02:00:00:00:00:02",
            interface="enp-test", source_ip="169.254.250.11",
        )

        def connected(board, **_kwargs):
            device = MagicMock()
            role = "master" if board.device_uid == "master-uid" else "slave"
            device.status.return_value = SimpleNamespace(
                capabilities=SimpleNamespace(sync_role=role)
            )
            return device

        def provisioned(board, ip, mac=None, **_kwargs):
            return SimpleNamespace(
                device_uid=board.device_uid,
                ip=ip,
                mac=mac or board.current_mac,
                port=1234,
            )

        assignments = [
            hardware_test_network.BoardNetworkAssignment(
                label="主卡", sync_role="master", ip="10.50.0.101"
            ),
            hardware_test_network.BoardNetworkAssignment(
                label="从卡", sync_role="slave", ip="10.50.0.102"
            ),
        ]
        with (
            patch.object(
                hardware_test_network,
                "discover_boards",
                return_value=[slave_board, master_board],
            ) as discover,
            patch.object(
                hardware_test_network,
                "connect_discovered",
                side_effect=connected,
            ),
            patch.object(
                hardware_test_network,
                "provision_board",
                side_effect=provisioned,
            ) as provision,
        ):
            enrolled = hardware_test_network.discover_and_provision_boards(
                assignments,
                interface="enp-test",
                discovery_source_ip="169.254.250.11",
                discovery_source_cidr="169.254.250.11/16",
                control_source_ip="10.50.0.10",
            )

        self.assertEqual(
            [(item.sync_role, item.device_uid, item.ip) for item in enrolled],
            [
                ("master", "master-uid", "10.50.0.101"),
                ("slave", "slave-uid", "10.50.0.102"),
            ],
        )
        discover.assert_called_once_with(
            interface="enp-test",
            source_ip="169.254.250.11",
            source_cidr="169.254.250.11/16",
            broadcast_ip="169.254.255.255",
            port=1234,
            timeout_s=1.0,
            rounds=3,
        )
        self.assertEqual(
            [call.kwargs["verification_source_ip"] for call in provision.call_args_list],
            ["10.50.0.10", "10.50.0.10"],
        )

    def test_interleaved_layout_uses_ch1_to_ch8_lanes(self):
        """检查多个物理通道写入 512-bit 交织 DDR 布局的正确 lane。"""
        image, samples = pack_interleaved_512b_waveforms({1: np.array([1, 2, 3, 4], dtype=np.int16), 2: np.array([5, 6, 7, 8], dtype=np.int16)})
        self.assertEqual(samples, 16)
        self.assertEqual(struct.unpack_from("<hhhh", image, 0), (1, 2, 3, 4))
        self.assertEqual(struct.unpack_from("<hhhh", image, 8), (5, 6, 7, 8))

    def test_simulator_state_machine_and_unsupported_capability(self):
        """检查模拟器的基本上传、ARM、软件 Trigger、停止和能力拒绝路径。"""
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

    def test_simulator_bypass_models_xs18_to_xs19_loopback(self):
        """检查 simulator 中 bypass 会放开 XS18->XS19 的本地回环门控。"""
        device = SimulatedDr47Device(batch_mode=True, sync_role="slave")
        device.connect()
        device.bypass_sync()
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

    def test_slave_external_rejects_triggers_until_explicit_bypass(self):
        """检查从卡 external 模式先拒绝 Trigger，bypass 后才开放。"""
        device = SimulatedDr47Device(batch_mode=True, sync_role="slave")
        device.connect()
        device.set_xy_nco_frequency(1, 1.0)
        device.apply_rfdc_config(channel_mask=0x01)
        device.set_qc_on_off("xy", 1, "on")
        device.upload_waveforms({1: np.array([1200, 0, 1200, 0], dtype=np.int16)}, wave_formats={1: "interleaved_iq"})
        device.arm(channel_mask=0x01)
        with self.assertRaises(DeviceStatusError):
            device.trigger()
        device.emit_trigger()
        status = device.status(refresh=False)
        self.assertFalse(status.capabilities.sync_seen)
        self.assertFalse(status.capabilities.sync_link_ready)
        self.assertEqual(status.capabilities.trigger_input_count, 1)
        self.assertEqual(status.capabilities.trigger_accepted_count, 0)
        self.assertEqual(status.state.value, "armed")
        device.abort_mute()

        device.bypass_sync()
        status = device.status(refresh=False)
        self.assertEqual(status.capabilities.sync_mode, "bypass")
        self.assertFalse(status.capabilities.sync_seen)
        self.assertTrue(status.capabilities.sync_link_ready)

    def test_slave_bypass_accepts_software_trigger_without_physical_io(self):
        """检查从卡 bypass 后的 UDP Trigger 不伪造 XS20，也不计入 XS18/XS19。

        这对应 ``hardware_slave_bypass_trigger_test.py`` 的软件 Trigger 模式核心路径：
        模拟器只验证数字状态机，真实 RF 输出仍需上板和仪器确认。
        """

        device = SimulatedDr47Device(batch_mode=True, sync_role="slave")
        device.connect()
        device.bypass_sync()
        device.set_xy_nco_frequency(1, 0.1)
        device.apply_rfdc_config(channel_mask=0x01)
        device.set_qc_on_off("xy", 1, "on")
        device.upload_waveforms(
            {1: np.array([1200, 0, 1200, 0], dtype=np.int16)},
            wave_formats={1: "interleaved_iq"},
        )
        device.arm(channel_mask=0x01)
        before = device.status(refresh=False).capabilities
        device.trigger()  # 仅发送本地 UDP 控制，不经过 XS18/XS19。
        after = device.status(refresh=False)
        self.assertEqual(after.state.value, "running")
        self.assertFalse(after.capabilities.sync_seen)
        self.assertEqual(after.capabilities.trigger_input_count, before.trigger_input_count)
        self.assertEqual(after.capabilities.trigger_output_count, before.trigger_output_count)

    def test_master_runs_locally_before_sync_and_role_cannot_change(self):
        """检查主卡无需 sync() 即可运行，且运行时不能篡改固化角色。"""
        device = SimulatedDr47Device(batch_mode=True, sync_role="master")
        device.connect()
        with self.assertRaises(SynchronizationError):
            device.set_sync_role("slave")
        device.set_xy_nco_frequency(1, 1.0)
        device.apply_rfdc_config(channel_mask=0x01)
        device.set_qc_on_off("xy", 1, "on")
        device.upload_waveforms({1: np.array([1200, 0, 1200, 0], dtype=np.int16)}, wave_formats={1: "interleaved_iq"})
        device.arm(channel_mask=0x01)
        device.trigger()
        self.assertEqual(device.status(refresh=False).state.value, "running")
        device.abort_mute()
        device.arm(channel_mask=0x01)
        device.emit_trigger()
        status = device.status(refresh=False)
        self.assertEqual(status.state.value, "running")
        self.assertEqual(status.capabilities.trigger_accepted_count, 1)

    def test_negative_nco_preserves_explicit_nyquist_zone(self):
        """检查设置负 NCO 时不会错误覆盖用户明确指定的 Nyquist zone。"""
        device = SimulatedDr47Device(batch_mode=True)
        device.connect()
        device.apply_rfdc_config(nyquist_zone={1: 1}, channel_mask=0x01)
        device.set_xy_nco_frequency(1, -0.1)
        self.assertEqual(device._pending_zone[1], 1)

    def test_public_frequency_api_uses_ghz_and_converts_at_protocol_boundary(self):
        """检查公共 API 用 GHz，只有到 RFCTRL2 边界才转换为整数 Hz。"""
        device = SimulatedDr47Device(batch_mode=True)
        device.connect()
        device.set_xy_nco_frequency(1, 1.79)
        self.assertEqual(device._pending_nco[1], 1_790_000_000.0)
        device.apply_rfdc_config(nco_ghz={1: -1.5}, channel_mask=0x01)
        self.assertEqual(device._pending_nco[1], -1_500_000_000.0)
        self.assertEqual(RFDC_NCO_MIN_GHZ, -3.2)
        self.assertEqual(RFDC_NCO_MAX_GHZ, 3.2)

    def test_public_target_plan_returns_ghz(self):
        """检查射频目标规划返回 NCO GHz、Nyquist zone 和镜像方向。"""
        self.assertEqual(rfdc_nco_plan_for_target(1.79), {
            "target_rf_ghz": 1.79,
            "nco_ghz": 1.79,
            "nyquist_zone": 1,
            "image": "direct",
        })
        zone2 = rfdc_nco_plan_for_target(4.5)
        self.assertEqual(zone2["nco_ghz"], -1.9)
        self.assertEqual(zone2["nyquist_zone"], 2)

    def test_set_xy_target_frequency_maps_above_3_2ghz_to_zone2(self):
        """目标 RF=4 GHz 时，驱动应自动设置 NCO=-2.4 GHz、Nyquist zone=2。"""
        device = SimulatedDr47Device(batch_mode=True)
        device.connect()
        plan = device.set_xy_target_frequency(1, 4.0)
        self.assertEqual(plan["target_rf_ghz"], 4.0)
        self.assertEqual(plan["nco_ghz"], -2.4)
        self.assertEqual(plan["nyquist_zone"], 2)
        self.assertEqual(device._pending_nco[1], -2_400_000_000.0)
        self.assertEqual(device._pending_zone[1], 2)

    def test_public_waveform_helpers_and_trigger_sequence(self):
        """检查正式驱动的 IQ 波形、记录延迟和等待 Trigger 指令。"""
        sample_rate_hz = 400e6
        sine_count = iq_duration_to_interleaved_sample_count(100e-9, sample_rate_hz)
        gaussian_count = iq_duration_to_interleaved_sample_count(60e-9, sample_rate_hz)
        sine = make_iq_sine_interleaved(0.0, 0.0, 16384, sample_rate_hz, sample_count=sine_count)
        gaussian = make_iq_gaussian_sine_interleaved(
            0.0, 0.0, 16384, sample_rate_hz, 60e-9, sample_count=gaussian_count
        )
        self.assertEqual(sine.shape, (80,))
        self.assertEqual(gaussian.shape, (48,))
        self.assertLess(abs(int(gaussian[0])), abs(int(gaussian[24])))
        sequence = make_trigger_sequence(24)
        self.assertEqual(sequence.dtype, np.dtype("<u2"))
        self.assertEqual(sequence[1, 3] >> 11, 8)

    def test_public_api_does_not_expose_removed_aliases(self):
        """旧状态属性不应重新作为兼容入口暴露。"""
        self.assertFalse(hasattr(DeviceCapabilities(), "rfcd_ready"))
        self.assertFalse(hasattr(DeviceCapabilities(), "capabilities"))

    def test_waveform_record_uses_web_manual_xy_contract(self):
        """检查正式波形工具遵守网页手动 XY 的零填充和延迟约定。"""
        sample_rate_hz = 400e6
        active = make_iq_gaussian_sine_interleaved(
            0.0, 0.0, 32767, sample_rate_hz, 120e-9,
            sample_count=iq_duration_to_interleaved_sample_count(120e-9, sample_rate_hz),
        )
        record = place_interleaved_iq_in_record(
            active, delay_s=80e-9, record_duration_s=1e-6, sample_rate_hz=sample_rate_hz
        )
        # 1 us at 400 MS/s is 400 complex samples, already 8-sample aligned.
        self.assertEqual(record.shape, (800,))
        start = 80 * 0.4 * 2
        end = start + 120 * 0.4 * 2
        self.assertTrue(np.all(record[:int(start)] == 0))
        self.assertTrue(np.any(record[int(start):int(end)] != 0))
        self.assertTrue(np.all(record[int(end):] == 0))
        # The web manual waveform uses negative-Q complex convention.
        self.assertEqual(int(record[int(start) + 1]), 0)
        self.assertEqual(int(record[int(start) + 3]), 0)

    def test_single_trigger_sequence_is_finite(self):
        sequence = make_single_trigger_sequence(24)
        commands, meta = __import__("dr47.waveforms", fromlist=["sequence_to_play_commands"]).sequence_to_play_commands(
            sequence, channel=1, wave_format="interleaved_iq"
        )
        self.assertTrue(meta["wait_for_trigger"])
        self.assertFalse(meta["loop"])
        self.assertEqual(commands[-1][0], 3)
        self.assertEqual(commands[-1][4], 0)

    def test_driver_record_is_byte_identical_to_web_manual_xy(self):
        """检查同一波形在驱动工具和网页模型中逐字节一致。"""
        sample_rate_hz = 400e6
        web_config = waveform_model.ChannelWaveformConfig(
            waveform_type="xy",
            domain="iq",
            freq_hz=0.0,
            phase_rad=0.0,
            amplitude=32767,
            delay_s=80e-9,
            duration_s=120e-9,
            record_duration_s=1e-6,
        )
        web_record = waveform_model._make_channel_waveform(web_config, 400e6, 16, "CH1")
        active = make_iq_gaussian_sine_interleaved(
            0.0, 0.0, 32767, sample_rate_hz, 120e-9,
            sample_count=iq_duration_to_interleaved_sample_count(120e-9, sample_rate_hz),
            fwhm_s=60e-9, q_sign=-1, hls_xy_drag=False,
        )
        driver_record = place_interleaved_iq_in_record(
            active, delay_s=80e-9, record_duration_s=1e-6, sample_rate_hz=sample_rate_hz
        )
        self.assertEqual(driver_record.dtype, web_record.dtype)
        self.assertEqual(driver_record.tobytes(), web_record.tobytes())
        self.assertEqual(
            host.pack_interleaved_512b_waveforms({1: web_record})[0],
            pack_interleaved_512b_waveforms({1: driver_record})[0],
        )

    def test_driver_upload_packets_match_web_manual_xy(self):
        """The normal driver upload must be wire-identical to web upload."""

        sample_rate_hz = 400e6
        active = make_iq_gaussian_sine_interleaved(
            0.0, 0.0, 32767, sample_rate_hz, 120e-9,
            sample_count=iq_duration_to_interleaved_sample_count(120e-9, sample_rate_hz),
            fwhm_s=60e-9, q_sign=-1, hls_xy_drag=False,
        )
        record = place_interleaved_iq_in_record(
            active, delay_s=80e-9, record_duration_s=1e-6, sample_rate_hz=sample_rate_hz
        )
        transport = _CaptureTransport()
        device = Dr47Device(transport=transport)
        upload = device.upload_waveforms(
            {1: record},
            wave_formats={1: "interleaved_iq"},
            auto_start=False,
            loop=False,
            channel_delays={1: 0},
            instruction_repeats=3,
            packet_pause_s=0.0,
        )

        web_commands = waveform_tools.build_play_commands(
            loop=False,
            auto_start=False,
            channel_addrs={1: 0},
            channel_lengths={1: int(record.nbytes)},
            channel_delays={1: 0},
            enabled_channels=[1],
            layout=host.DDR_LAYOUT_INTERLEAVED_512B,
        )
        expected_ddr = list(host.iter_interleaved_udp_waveform_packets({1: record}, host.DDR_BASE))
        expected_instruction = host.pack_udp_instruction_packet(web_commands)
        self.assertEqual(upload["commands"], web_commands)
        self.assertEqual(upload["instruction_repeats"], 3)
        self.assertEqual(transport.sent, expected_ddr + [expected_instruction] * 3)


if __name__ == "__main__":
    unittest.main()
