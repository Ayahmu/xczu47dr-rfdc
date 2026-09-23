#!/usr/bin/env python3
"""Run the single-board WAVECTR0 API without a physical board."""

from __future__ import annotations

import numpy as np

from dr47 import PlaybackState, SimulatedDr47Device


def main() -> int:
    image = np.arange(128, dtype=np.int16).tobytes()
    with SimulatedDr47Device(batch_mode=True) as device:
        result = device.upload_waveforms(
            {1: np.arange(32, dtype=np.int16)},
            wave_formats={1: "z"},
            channel_mask=0x01,
            loop_count=1,
        )
        device.complete_prefetch()
        device.play(session=int(result["session"]))
        status = device.status(refresh=False)
        if status.state is not PlaybackState.PLAYING:
            raise RuntimeError(f"expected playing, got {status.state.value}")
        print(
            "driver simulation OK: "
            f"session={result['session']}, total_beats={result['total_beats']}, "
            f"state={status.state.value}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
