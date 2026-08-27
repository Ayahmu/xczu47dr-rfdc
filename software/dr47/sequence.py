"""Playback sequence helpers for the RFCTRL2 waveform player."""

from __future__ import annotations

import numpy as np


def make_trigger_sequence(sample_count: int) -> np.ndarray:
    """Return a loop that waits for one Trigger per record."""

    count = int(sample_count)
    if not 1 <= count <= 0xFFFF:
        raise ValueError("sample_count must be in 1..65535")
    return np.asarray(
        [
            [0, count, 0, 0x0800],
            [0, count, 0, 0x4000],
            [0, count, 0, 0x0000],
            [0, count, 0, 0x1000],
            [0, count, 0, 0x8000],
        ],
        dtype="<u2",
    )


__all__ = ["make_trigger_sequence"]
