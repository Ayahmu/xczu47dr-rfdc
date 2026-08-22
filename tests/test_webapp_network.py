import os
import struct
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, call, patch

from software import host
from software.webapp.controller import BoardGateway
from software.webapp.management import ManagementError
from software.webapp.models import (
    BoardProfile,
    BoardState,
    BoardStatus,
    PhaseCalibrationRecord,
    RfdcConfigApplyRequest,
)
from software.webapp.network import (
    FPGA_LINKLOCAL_DEFAULT_IP,
    auto_fpga_link_profile,
    discovery_target_profile,
    discovery_targets_for_interface,
    ensure_auto_link_ready,
    list_udp_interfaces,
    process_capability_report,
    udp_path_error,
)
from software.webapp.rfdc import RfdcConfigService, default_rfdc_config


class NetworkInterfaceTests(unittest.TestCase):
    def test_discovery_targets_include_dna_linklocal_default_ip(self):
        targets = discovery_targets_for_interface("enp225s0f0")
        self.assertIn("192.168.1.128", targets)
        self.assertIn("192.168.254.254", targets)
        self.assertIn(FPGA_LINKLOCAL_DEFAULT_IP, targets)
        self.assertIn("169.254.255.255", targets)
        self.assertIn("255.255.255.255", targets)
        self.assertEqual(len(targets), len(set(targets)))

    def test_fixed_interfaces_resolve_generic_build_to_master_and_slave_roles(self):
        self.assertEqual(auto_fpga_link_profile("enp225s0f0")["inventory_name"], "XCZU47DR 081")
        self.assertEqual(auto_fpga_link_profile("enp225s0f1")["inventory_name"], "XCZU47DR 082")
        self.assertEqual(discovery_target_profile("enp225s0f0", "custom_xczu47dr"), "custom_xczu47dr_master")
        self.assertEqual(discovery_target_profile("enp225s0f1", "custom_xczu47dr"), "custom_xczu47dr_slave")
        self.assertEqual(discovery_target_profile("enp225s0f1", "custom_xczu47dr_bw"), "custom_xczu47dr_bw")

    def test_inventory_returns_dedicated_and_host_ethernet_interfaces(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            connected = root / "enp225s0f1"
            connected.mkdir()
            (connected / "operstate").write_text("up\n", encoding="ascii")
            (connected / "carrier").write_text("1\n", encoding="ascii")

            host_ethernet = root / "eno1np0"
            host_ethernet.mkdir()
            (host_ethernet / "operstate").write_text("up\n", encoding="ascii")
            (host_ethernet / "carrier").write_text("1\n", encoding="ascii")

            interfaces = list_udp_interfaces(root)

        self.assertEqual([item.name for item in interfaces], ["enp225s0f0", "enp225s0f1", "eno1np0", "eno2np1"])
        self.assertFalse(interfaces[0].present)
        self.assertTrue(interfaces[1].carrier)
        self.assertTrue(interfaces[2].carrier)
        self.assertFalse(interfaces[3].present)
        self.assertIn("未配置 IPv4", interfaces[1].message)

    def test_auto_link_ready_brings_interface_up_and_adds_source_addresses(self):
        completed = Mock(returncode=0, stderr="", stdout="")
        with patch("software.webapp.network._ipv4_addresses", return_value=[]), patch(
            "software.webapp.network._read_text", side_effect=["down", "0"]
        ), patch(
            "software.webapp.network.subprocess.run", return_value=completed
        ) as run:
            added = ensure_auto_link_ready("enp225s0f1")

        self.assertEqual(added, ["192.168.2.10/24", "169.254.250.11/16", "192.168.254.11/24"])
        run.assert_has_calls([
            call(
                ["ip", "link", "set", "dev", "enp225s0f1", "up"],
                check=False,
                text=True,
                stdout=-1,
                stderr=-1,
            ),
            call(
                ["ip", "address", "replace", "192.168.2.10/24", "dev", "enp225s0f1"],
                check=False,
                text=True,
                stdout=-1,
                stderr=-1,
            ),
            call(
                ["ip", "address", "replace", "169.254.250.11/16", "dev", "enp225s0f1"],
                check=False,
                text=True,
                stdout=-1,
                stderr=-1,
            ),
            call(
                ["ip", "address", "replace", "192.168.254.11/24", "dev", "enp225s0f1"],
                check=False,
                text=True,
                stdout=-1,
                stderr=-1,
            ),
        ])

    def test_udp_path_error_reports_auto_config_permission_hint(self):
        board = BoardProfile(
            id="board-a",
            name="A",
            ip="192.168.1.128",
            mac="02:00:00:00:00:01",
            udp_interface="enp225s0f0",
            udp_source_ip="192.168.1.10",
            clock_source="onboard",
        )
        denied = Mock(returncode=2, stderr="RTNETLINK answers: Operation not permitted", stdout="")
        with patch("software.webapp.network.subprocess.run", return_value=denied):
            error = udp_path_error(board)

        self.assertIsNotNone(error)
        self.assertIn("CAP_NET_ADMIN", error)
        self.assertIn("CAP_NET_RAW", error)
        self.assertIn("AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW", error)
        self.assertNotIn("sudo ip", error)

    def test_process_capability_report_checks_effective_net_caps(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            status = Path(temp_dir) / "status"
            net_caps = (1 << 12) | (1 << 13)
            status.write_text(
                f"Name:\tpython\nCapPrm:\t{net_caps:016x}\nCapEff:\t{net_caps:016x}\nCapAmb:\t0000000000000000\n",
                encoding="ascii",
            )
            report = process_capability_report(status)

        self.assertTrue(report["ok"])
        self.assertEqual(report["missing"], [])
        self.assertEqual(report["effective"], ["CAP_NET_ADMIN", "CAP_NET_RAW"])

    def test_rfdc_network_failure_is_not_reported_as_a_playback_state_error(self):
        board = BoardProfile(
            id="board-a",
            name="A",
            ip="192.168.1.128",
            mac="",
            udp_interface="enp225s0f1",
            udp_source_ip="192.168.1.10",
            clock_source="onboard",
        )
        store = Mock()
        store.board.return_value = board
        store.load_rfdc_config.return_value = None
        boards = Mock()
        boards.status.return_value = BoardStatus(
            board_id=board.id,
            state=BoardState.OFFLINE,
            online=False,
            message="UDP 网卡 enp225s0f1 未配置源 IP 192.168.1.10",
        )
        service = RfdcConfigService(store, boards, Mock(), Mock())
        config = default_rfdc_config(board.id)

        with self.assertRaisesRegex(ManagementError, "enp225s0f1 / 192.168.1.10"):
            service.apply(
                board.id,
                RfdcConfigApplyRequest(channels=config.channels, channel_mask=1),
            )
        boards.rfdc_apply.assert_not_called()

    def test_rfdc_ready_state_is_allowed_when_playback_is_disarmed(self):
        board = BoardProfile(
            id="board-a",
            name="A",
            ip="192.168.1.128",
            mac="",
            clock_source="onboard",
        )
        config = default_rfdc_config(board.id)
        store = Mock()
        store.board.return_value = board
        store.load_rfdc_config.return_value = config
        store.save_rfdc_config.side_effect = lambda value: value
        boards = Mock()
        boards.status.return_value = BoardStatus(
            board_id=board.id,
            state=BoardState.READY,
            online=True,
            dac_mts_required=True,
            dac_mts_ready=True,
            dac_mts_tile_mask=0xF,
        )
        boards.rfdc_apply.return_value = {
            "status": 0,
            "revision": 1,
            "applied_mask": 1,
            "error_mask": 0,
            "config_valid_mask": 1,
            "channels": [],
        }
        events = Mock()
        service = RfdcConfigService(store, boards, Mock(), events)

        result = service.apply(
            board.id,
            RfdcConfigApplyRequest(channels=config.channels, channel_mask=1),
        )

        self.assertEqual(result.apply_status, "applied")
        boards.rfdc_apply.assert_called_once()

    def test_rfdc_apply_adds_exact_server_phase_calibration_to_nco(self):
        board = BoardProfile(
            id="board-a", name="A", ip="192.168.1.128", mac="", device_uid="dna-1", clock_source="onboard"
        )
        config = default_rfdc_config(board.id)
        store = Mock()
        store.board.return_value = board
        store.load_rfdc_config.return_value = config
        store.save_rfdc_config.side_effect = lambda value: value
        store.list_phase_calibrations.return_value = [
            PhaseCalibrationRecord(
                board_id=board.id, device_uid=board.device_uid, frequency_hz=4_500_000_000,
                channel=1, phase_deg=12.5, updated_at="2026-01-01T00:00:00+00:00",
            )
        ]
        boards = Mock()
        boards.status.return_value = BoardStatus(
            board_id=board.id, state=BoardState.READY, online=True,
            dac_mts_required=True, dac_mts_ready=True, dac_mts_tile_mask=0xF,
        )
        boards.rfdc_apply.return_value = {
            "status": 0, "revision": 1, "applied_mask": 1, "error_mask": 0,
            "config_valid_mask": 1, "channels": [],
        }
        result = RfdcConfigService(store, boards, Mock(), Mock()).apply(
            board.id, RfdcConfigApplyRequest(channels=config.channels, channel_mask=1)
        )
        hardware_channels = boards.rfdc_apply.call_args.args[1]
        self.assertEqual(hardware_channels[0].nco_phase_deg, 12.5)
        self.assertEqual(result.channels[0].nco_phase_deg, 0.0)
        self.assertEqual(result.channels[0].calibration_phase_deg, 12.5)

    def test_rfdc_apply_rejects_bitstream_without_mts_declaration(self):
        board = BoardProfile(id="board-a", name="A", ip="192.168.1.128", mac="", clock_source="onboard")
        config = default_rfdc_config(board.id)
        store = Mock()
        store.board.return_value = board
        store.load_rfdc_config.return_value = config
        boards = Mock()
        boards.status.return_value = BoardStatus(
            board_id=board.id,
            state=BoardState.READY,
            online=True,
            rfdc_ready=True,
        )

        with self.assertRaisesRegex(ManagementError, "does not declare mandatory DAC MTS"):
            RfdcConfigService(store, boards, Mock(), Mock()).apply(
                board.id,
                RfdcConfigApplyRequest(channels=config.channels, channel_mask=1),
            )
        boards.rfdc_apply.assert_not_called()

    def test_control_timeout_clears_stale_hardware_and_playback_state(self):
        board = BoardProfile(
            id="board-a",
            name="A",
            ip="192.168.1.128",
            mac="",
            udp_interface="enp225s0f1",
            udp_source_ip="192.168.1.10",
            clock_source="onboard",
        )
        gateway = BoardGateway(boards=(board,))
        _ = gateway.boards
        gateway._set_status(
            board.id,
            state=BoardState.RUNNING,
            online=True,
            protocol_version=2,
            rfdc_ready=True,
            rfdc_config_busy=True,
            playback_armed=True,
            playback_prepared=True,
            playback_running=True,
        )
        controller = Mock()
        controller.rfctrl2_status.side_effect = TimeoutError("RFCTRL2 response timeout")

        with patch("software.webapp.controller.udp_path_error", return_value=None), patch.object(
            BoardGateway, "_controller", return_value=controller
        ):
            status = gateway.refresh(board.id)

        self.assertFalse(status.online)
        self.assertEqual(status.protocol_version, 0)
        self.assertIsNone(status.rfdc_ready)
        self.assertFalse(status.rfdc_config_busy)
        self.assertFalse(status.playback_armed)
        self.assertFalse(status.playback_prepared)
        self.assertFalse(status.playback_running)

    def test_online_idle_status_clears_stale_fault_after_board_reboot(self):
        board = BoardProfile(
            id="board-a",
            name="A",
            ip="192.168.1.128",
            mac="",
            udp_interface="enp225s0f0",
            udp_source_ip="192.168.1.10",
            clock_source="onboard",
        )
        gateway = BoardGateway(boards=(board,))
        gateway.boards
        gateway._set_status(
            board.id,
            state=BoardState.FAULT,
            online=False,
            message="stale error from the previous playback run",
        )
        status_payload = struct.pack(
            "<IIIIIIIIQQQQ",
            host.RF2_CAP_PL_RFDC_CONFIG,
            host.RF2_STATUS_DAC_MTS_REQUIRED,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            (0xF << 4) | 0x04,
        )
        controller = Mock()
        controller.rfctrl2_status.return_value = {
            "version": host.RFCTRL2_VERSION,
            "status": host.RF2_STATUS_OK,
            "payload": status_payload,
        }

        with patch("software.webapp.controller.udp_path_error", return_value=None), patch.object(
            BoardGateway, "_controller", return_value=controller
        ):
            status = gateway.refresh(board.id)

        self.assertTrue(status.online)
        self.assertEqual(status.state, BoardState.IDLE)
        self.assertFalse(status.playback_armed)
        self.assertFalse(status.playback_prepared)
        self.assertFalse(status.playback_running)
        self.assertEqual(status.message, "RFCTRL2 online; RFDC tiles are not ready")

    def test_arm_timeout_requests_abort_mute_and_reports_debug_status(self):
        board = BoardProfile(
            id="board-a",
            name="A",
            ip="192.168.1.128",
            mac="",
            udp_interface="enp225s0f0",
            udp_source_ip="192.168.1.10",
            clock_source="onboard",
        )
        gateway = BoardGateway(boards=(board,))
        _ = gateway.boards
        ready = BoardStatus(
            board_id=board.id,
            state=BoardState.READY,
            online=True,
            protocol_version=2,
            rfdc_ready=True,
            rfdc_capabilities=host.RF2_CAP_PL_RFDC_CONFIG | host.RF2_CAP_DAC_MTS | host.RF2_CAP_NCO_SYNC,
            rfdc_config_valid_mask=0x03,
            dac_mts_required=True,
            dac_mts_ready=True,
            dac_mts_tile_mask=0xF,
            nco_sync_ready=True,
            nco_sync_epoch=1,
        )
        status_payload = struct.pack(
            "<IIIIIIIIQQQQ",
            host.RF2_CAP_PL_RFDC_CONFIG,
            host.RF2_STATUS_RFDC_READY | host.RF2_STATUS_ARMED,
            0x03,
            1,
            0,
            0,
            0,
            0,
            (0x01 << 32) | 0x03,
            (0x02 << 32) | 0x00,
            0,
            0,
        )
        controller = Mock()
        controller.rfctrl2_arm.return_value = {"version": host.RFCTRL2_VERSION, "status": 0}
        controller.rfctrl2_status.return_value = {
            "version": host.RFCTRL2_VERSION,
            "status": 0,
            "payload": status_payload,
        }
        controller.rfctrl2_abort_mute.return_value = {"version": host.RFCTRL2_VERSION, "status": 0}

        with patch.dict(os.environ, {"RFSOC_WEB_ARM_PREPARE_TIMEOUT_S": "0.001"}), patch.object(
            gateway, "refresh", return_value=ready
        ), patch.object(
            BoardGateway, "_controller", return_value=controller
        ):
            with self.assertRaisesRegex(TimeoutError, "prepared=0.*play_config_mask=0x03.*executor_state=0x02"):
                gateway.arm(board.id, run_token=0x1234, channel_mask=0x03)

        controller.rfctrl2_abort_mute.assert_called_once()
        controller.close.assert_called_once()

    def test_trigger_timeout_requests_abort_mute_and_reports_debug_status(self):
        board = BoardProfile(
            id="board-a",
            name="A",
            ip="192.168.1.128",
            mac="",
            udp_interface="enp225s0f0",
            udp_source_ip="192.168.1.10",
            clock_source="onboard",
        )
        gateway = BoardGateway(boards=(board,))
        _ = gateway.boards
        prepared = BoardStatus(
            board_id=board.id,
            state=BoardState.ARMED,
            online=True,
            protocol_version=2,
            rfdc_ready=True,
            rfdc_capabilities=host.RF2_CAP_PL_RFDC_CONFIG,
            rfdc_config_valid_mask=0x03,
            playback_armed=True,
            playback_prepared=True,
        )
        status_payload = struct.pack(
            "<IIIIIIIIQQQQ",
            host.RF2_CAP_PL_RFDC_CONFIG,
            host.RF2_STATUS_RFDC_READY | host.RF2_STATUS_ARMED,
            0x03,
            1,
            0,
            0,
            0,
            0,
            (0x01 << 32) | 0x03,
            (0x02 << 32) | 0x00,
            0,
            0,
        )
        controller = Mock()
        controller.rfctrl2_trigger.return_value = {"version": host.RFCTRL2_VERSION, "status": 0}
        controller.rfctrl2_status.return_value = {
            "version": host.RFCTRL2_VERSION,
            "status": 0,
            "payload": status_payload,
        }
        controller.rfctrl2_abort_mute.return_value = {"version": host.RFCTRL2_VERSION, "status": 0}

        with patch.dict(os.environ, {"RFSOC_WEB_TRIGGER_RUNNING_TIMEOUT_S": "0.001"}), patch.object(
            gateway, "refresh", return_value=prepared
        ), patch.object(
            BoardGateway, "_controller", return_value=controller
        ):
            with self.assertRaisesRegex(TimeoutError, "running=0.*play_config_mask=0x03.*executor_state=0x02"):
                gateway.manual_trigger(board.id)

        controller.rfctrl2_abort_mute.assert_called_once()
        controller.close.assert_called_once()

    def test_short_one_shot_trigger_accepts_executor_progress_without_abort(self):
        board = BoardProfile(
            id="board-a",
            name="A",
            ip="192.168.1.128",
            mac="",
            udp_interface="enp225s0f0",
            udp_source_ip="192.168.1.10",
            clock_source="onboard",
        )
        gateway = BoardGateway(boards=(board,))
        _ = gateway.boards
        prepared = BoardStatus(
            board_id=board.id,
            state=BoardState.ARMED,
            online=True,
            protocol_version=2,
            rfdc_ready=True,
            rfdc_capabilities=host.RF2_CAP_PL_RFDC_CONFIG,
            rfdc_config_valid_mask=0x03,
            playback_armed=True,
            playback_prepared=True,
        )
        status_payload = struct.pack(
            "<IIIIIIIIQQQQ",
            host.RF2_CAP_PL_RFDC_CONFIG,
            host.RF2_STATUS_RFDC_READY | host.RF2_STATUS_ARMED,
            0x03,
            1,
            0,
            0,
            0,
            0,
            (0x00 << 32) | 0x03,
            (0x03 << 32) | 0xFF,
            212,
            0x0000000300000001,
        )
        controller = Mock()
        controller.rfctrl2_trigger.return_value = {"version": host.RFCTRL2_VERSION, "status": 0}
        controller.rfctrl2_status.return_value = {
            "version": host.RFCTRL2_VERSION,
            "status": 0,
            "payload": status_payload,
        }
        controller.rfctrl2_abort_mute.return_value = {"version": host.RFCTRL2_VERSION, "status": 0}

        with patch.dict(os.environ, {"RFSOC_WEB_TRIGGER_RUNNING_TIMEOUT_S": "0.001"}), patch.object(
            gateway, "refresh", return_value=prepared
        ), patch.object(
            BoardGateway, "_controller", return_value=controller
        ):
            gateway.manual_trigger(board.id, expect_sustained=False)

        controller.rfctrl2_abort_mute.assert_not_called()
        controller.close.assert_called_once()

    def test_short_one_shot_trigger_accepts_ddr_progress_after_playback_finished(self):
        board = BoardProfile(
            id="board-a",
            name="A",
            ip="192.168.1.128",
            mac="",
            udp_interface="enp225s0f0",
            udp_source_ip="192.168.1.10",
            clock_source="onboard",
        )
        gateway = BoardGateway(boards=(board,))
        _ = gateway.boards
        prepared = BoardStatus(
            board_id=board.id,
            state=BoardState.ARMED,
            online=True,
            protocol_version=2,
            rfdc_ready=True,
            rfdc_capabilities=host.RF2_CAP_PL_RFDC_CONFIG,
            rfdc_config_valid_mask=0x03,
            playback_armed=True,
            playback_prepared=True,
            play_ddr_read_counter=52,
        )
        status_payload = struct.pack(
            "<IIIIIIIIQQQQ",
            host.RF2_CAP_PL_RFDC_CONFIG,
            host.RF2_STATUS_RFDC_READY | host.RF2_STATUS_ARMED,
            0x03,
            1,
            0,
            0,
            0,
            0,
            0,
            (0x00000000 << 32) | 0xFF,
            212,
            0,
        )
        controller = Mock()
        controller.rfctrl2_trigger.return_value = {"version": host.RFCTRL2_VERSION, "status": 0}
        controller.rfctrl2_status.return_value = {
            "version": host.RFCTRL2_VERSION,
            "status": 0,
            "payload": status_payload,
        }
        controller.rfctrl2_abort_mute.return_value = {"version": host.RFCTRL2_VERSION, "status": 0}

        with patch.dict(os.environ, {"RFSOC_WEB_TRIGGER_RUNNING_TIMEOUT_S": "0.001"}), patch.object(
            gateway, "refresh", return_value=prepared
        ), patch.object(
            BoardGateway, "_controller", return_value=controller
        ):
            gateway.manual_trigger(board.id, expect_sustained=False)

        controller.rfctrl2_abort_mute.assert_not_called()
        controller.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
