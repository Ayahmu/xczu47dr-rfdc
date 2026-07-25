import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from software.webapp.controller import BoardGateway
from software.webapp.management import ManagementError
from software.webapp.models import (
    BoardProfile,
    BoardRole,
    BoardState,
    BoardStatus,
    RfdcConfigApplyRequest,
)
from software.webapp.network import list_udp_interfaces
from software.webapp.rfdc import RfdcConfigService, default_rfdc_config


class NetworkInterfaceTests(unittest.TestCase):
    def test_inventory_always_returns_the_two_supported_udp_interfaces(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            connected = root / "enp225s0f1"
            connected.mkdir()
            (connected / "operstate").write_text("up\n", encoding="ascii")
            (connected / "carrier").write_text("1\n", encoding="ascii")

            interfaces = list_udp_interfaces(root)

        self.assertEqual([item.name for item in interfaces], ["enp225s0f0", "enp225s0f1"])
        self.assertFalse(interfaces[0].present)
        self.assertTrue(interfaces[1].carrier)
        self.assertIn("未配置 IPv4", interfaces[1].message)

    def test_rfdc_network_failure_is_not_reported_as_a_playback_state_error(self):
        board = BoardProfile(
            id="board-a",
            name="A",
            role=BoardRole.MASTER,
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
            role=BoardRole.MASTER,
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

    def test_control_timeout_clears_stale_hardware_and_playback_state(self):
        board = BoardProfile(
            id="board-a",
            name="A",
            role=BoardRole.MASTER,
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


if __name__ == "__main__":
    unittest.main()
