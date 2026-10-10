"""The live RFDC apply path must not carry a DAC output current."""

import sys
import threading
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "software"))
sys.path.insert(0, str(ROOT))

import dr47 as driver  # noqa: E402
from software.webapp.controller import BoardGateway  # noqa: E402
from software.webapp.models import RfdcChannelConfig  # noqa: E402


class LiveRfdcApplyPathTests(unittest.TestCase):
    def test_live_apply_sends_nco_zone_and_phase_only(self):
        gateway = object.__new__(BoardGateway)
        gateway.simulation = False
        gateway._next_sequence = MagicMock(return_value=5)
        gateway._board_control_lock = MagicMock(return_value=threading.RLock())
        gateway.profile = MagicMock(return_value=object())
        gateway.refresh = MagicMock(return_value=MagicMock(rfdc_capabilities=driver.RF2_CAP_PL_RFDC_CONFIG))
        controller = MagicMock()
        channels = [RfdcChannelConfig(channel=channel, nco_hz=1e6 * channel, nyquist_zone=1) for channel in range(1, 9)]
        with patch.object(BoardGateway, "_controller", return_value=controller):
            gateway.rfdc_apply("board-a", channels, revision=3, channel_mask=0xFF)
        controller.rfctrl2_rfdc_apply.assert_called_once()
        args, kwargs = controller.rfctrl2_rfdc_apply.call_args
        self.assertEqual(len(args), 3)  # nco, nyquist zone, phase
        self.assertEqual(args[0][3], 3e6)  # keyed by channel number
        self.assertEqual(kwargs["revision"], 3)
        self.assertEqual(kwargs["channel_mask"], 0xFF)


if __name__ == "__main__":
    unittest.main()
