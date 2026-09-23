import os
import unittest
from unittest.mock import Mock, patch

from software.webapp.controller import BoardGateway
from software.webapp.models import BoardProfile, BoardState, BoardStatus


class WaveformGatewayV2Tests(unittest.TestCase):
    def setUp(self):
        self.old_simulation = os.environ.get("RFSOC_WEB_SIMULATION")
        os.environ["RFSOC_WEB_SIMULATION"] = "0"
        self.board = BoardProfile(
            id="board-a",
            name="A",
            ip="192.168.1.128",
            mac="",
            udp_interface="enp225s0f0",
            udp_source_ip="192.168.1.10",
            clock_source="onboard",
        )
        self.gateway = BoardGateway(boards=(self.board,))
        self.gateway.boards
        self.controller = Mock()
        self.controller.waveform_status.side_effect = [
            {"status": 0, "state_name": "wait_trigger", "state": 4, "session": 0x1234, "descriptor": 9},
            {"status": 0, "state_name": "playing", "state": 5, "session": 0x1234, "descriptor": 9},
        ]
        self.controller.play.return_value = {"status": 0, "state_name": "playing", "state": 5, "session": 0x1234}
        self.controller.stop.return_value = {"status": 0, "state_name": "ready", "state": 2, "session": 0x1234}
        self.controller.abort.return_value = {"status": 0, "state_name": "idle", "state": 0, "session": 0}

    def tearDown(self):
        if self.old_simulation is None:
            os.environ.pop("RFSOC_WEB_SIMULATION", None)
        else:
            os.environ["RFSOC_WEB_SIMULATION"] = self.old_simulation

    def _patch_controller(self):
        return patch.object(BoardGateway, "_controller", return_value=self.controller)

    def test_arm_checks_waveform_status_without_legacy_arm_command(self):
        with self._patch_controller():
            self.gateway.arm(self.board.id, session=0x1234)

        self.controller.connect.assert_called_once_with()
        self.controller.waveform_status.assert_called_once_with(session=0x1234)
        self.controller.rfctrl2_arm.assert_not_called()
        self.controller.close.assert_called_once_with()
        status = self.gateway.status(self.board.id, refresh=False)
        self.assertEqual(status.state, BoardState.ARMED)
        self.assertTrue(status.playback_prepared)

    def test_manual_trigger_uses_waveform_play_for_same_session(self):
        self.gateway._set_status(
            self.board.id,
            state=BoardState.ARMED,
            online=True,
            playback_prepared=True,
        )
        # PLAY acknowledgement and the subsequent STATUS snapshot are distinct
        # protocol responses.  The status used here must describe the post-PLAY
        # hardware state; returning WAIT_TRIGGER would be an invalid fixture for
        # this test, not evidence that the gateway should accept a stale snapshot.
        self.controller.waveform_status.side_effect = [
            {"status": 0, "state_name": "playing", "state": 5, "session": 0x1234, "descriptor": 9},
        ]
        with self._patch_controller():
            self.gateway.manual_trigger(self.board.id, session=0x1234)

        self.controller.connect.assert_called_once_with()
        self.controller.play.assert_called_once_with(session=0x1234)
        self.controller.rfctrl2_trigger.assert_not_called()
        self.controller.close.assert_called_once_with()
        status = self.gateway.status(self.board.id, refresh=False)
        self.assertEqual(status.state, BoardState.RUNNING)
        self.assertTrue(status.playback_running)

    def test_stop_and_abort_use_waveform_commands_and_explicit_session(self):
        with self._patch_controller():
            self.gateway.mute(self.board.id, session=0x1234)
        self.controller.connect.assert_called_once_with()
        self.controller.stop.assert_called_once_with(session=0x1234)
        self.controller.rfctrl2_abort_mute.assert_not_called()
        self.controller.close.assert_called_once_with()

        self.controller.reset_mock()
        with self._patch_controller():
            self.gateway.abort(self.board.id, session=0x1234)
        self.controller.connect.assert_called_once_with()
        self.controller.abort.assert_called_once_with(session=0x1234)
        self.controller.rfctrl2_abort_mute.assert_not_called()
        self.controller.close.assert_called_once_with()

    def test_session_mismatch_is_rejected_before_play(self):
        self.gateway._set_status(
            self.board.id,
            state=BoardState.ARMED,
            online=True,
            playback_prepared=True,
        )
        self.controller.play.side_effect = RuntimeError("waveform session mismatch")
        with self._patch_controller():
            with self.assertRaisesRegex(RuntimeError, "session"):
                self.gateway.manual_trigger(self.board.id, session=0x9999)
        self.controller.play.assert_called_once_with(session=0x9999)
    def test_ready_waveform_keeps_descriptor_but_is_disarmed_for_host_guards(self):
        fields = self.gateway._waveform_status_fields({
            "status": 0,
            "state": 2,
            "state_name": "ready",
            "session": 0x1234,
            "descriptor": 9,
        })

        self.assertEqual(fields["state"], BoardState.READY)
        self.assertFalse(fields["playback_armed"])
        self.assertFalse(fields["playback_prepared"])
        self.assertFalse(fields["playback_running"])
        self.assertEqual(fields["waveform_session"], 0x1234)
        self.assertEqual(fields["waveform_descriptor"], 9)

    def test_refresh_uses_waveform_status_for_playback_state(self):
        self.controller.rfctrl2_status.return_value = {
            "status": 0,
            "version": 3,
        }
        self.controller.waveform_status.return_value = {
            "status": 0,
            "state": 5,
            "state_name": "playing",
            "session": 0x1234,
            "descriptor": 9,
            "current_beat": 17,
            "loop_position": 1,
            "loop_count": 2,
            "fifo_levels": (700,) * 8,
            "error_count": 0,
            "underflow_count": 0,
            "trigger_seen_count": 3,
            "trigger_dropped_count": 1,
            "trigger_fire_count": 1,
        }
        self.controller.waveform_status.side_effect = None
        decoded = {
            "rfdc_ready": True,
            "capabilities": 0,
            "config_valid_mask": 0xFF,
            "rfdc_busy": False,
            "dac_mts_required": False,
            "dac_mts_ready": True,
            "dac_mts_failed": False,
            "dac_mts_tile_mask": 0xF,
            "dac_mts_error": 0,
            "nco_sync_ready": True,
            "nco_sync_epoch": 4,
            "last_revision": 2,
            "last_error": 0,
            "last_error_stage": 0,
            "last_error_addr": 0,
        }
        with (
            self._patch_controller(),
            patch("software.webapp.controller.udp_path_error", return_value=""),
            patch("software.webapp.controller.list_udp_interfaces", return_value=[]),
            patch("software.webapp.controller.driver.parse_rfctrl2_status_payload", return_value=decoded),
        ):
            status = self.gateway.refresh(self.board.id)

        self.controller.waveform_status.assert_called_once_with(session=0)
        self.assertEqual(status.state, BoardState.RUNNING)
        self.assertEqual(status.waveform_session, 0x1234)
        self.assertEqual(status.waveform_current_beat, 17)
        self.assertEqual(status.waveform_fifo_levels, [700] * 8)
        self.assertEqual(status.trigger_dropped_count, 1)


if __name__ == "__main__":
    unittest.main()
