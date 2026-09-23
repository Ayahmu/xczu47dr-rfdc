"""Regression tests for the single-board WAVECTR0 playback contract."""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "software"))

from dr47 import SimulatedDr47Device  # noqa: E402
from dr47.capabilities import PlaybackState  # noqa: E402


class WaveformPlaybackTests:
    def test_upload_commit_prefetch_and_triggered_playback(self):
        device = SimulatedDr47Device()
        device.connect()

        uploaded = device.upload_waveforms(
            {1: np.arange(16, dtype=np.int16)}, channel_mask=0x01, loop_count=1
        )
        assert uploaded["total_beats"] == 1
        assert uploaded["channel_mask"] == 0x01
        assert device.status(refresh=False).state is PlaybackState.PREFETCH

        device.complete_prefetch()
        assert device.status(refresh=False).state is PlaybackState.WAIT_TRIGGER
        response = device.trigger_event()
        assert response is True
        assert device.status(refresh=False).state is PlaybackState.PLAYING

    def test_software_play_restarts_from_prefetch_without_legacy_schedule(self):
        device = SimulatedDr47Device()
        device.connect()
        device.upload_waveforms(
            {1: np.arange(16, dtype=np.int16)}, channel_mask=0x01, loop_count=1
        )
        device.complete_prefetch()
        device.trigger_event()
        assert device.status(refresh=False).state is PlaybackState.PLAYING

        response = device.play()
        assert response["status"] == 0
        assert response["state_name"] == "prefetch"


if __name__ == "__main__":
    import pytest

    raise SystemExit(pytest.main([__file__]))
