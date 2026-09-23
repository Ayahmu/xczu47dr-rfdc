#!/usr/bin/env python3
"""Single-board waveform smoke test with an external XS19 Trigger.

The script uploads one known CH1 waveform through WAVECTR0, commits the
waveform descriptor, and waits for the board to enter PLAYING after an external
Trigger.  It never emits a software Trigger and does not use the removed
master/slave, XS20 bypass, or instruction-playback APIs.

Before running, connect XS17 to the 250 MHz reference, connect the external
Trigger source to XS19, and terminate CH1 with 50 ohms.  Keep the amplitude
small until the digital path and the first observed waveform are confirmed.
All user-adjustable settings are constants below; this example intentionally
has no command-line or environment-variable interface.
"""

from __future__ import annotations

import math
import time

import numpy as np

from dr47 import Dr47Device, PlaybackState
from dr47.errors import DriverError

BOARD_IP = "169.254.149.60"
BOARD_PORT = 1234
UDP_INTERFACE = "enp1s0f0"
UDP_SOURCE_IP = "169.254.250.11"

OUTPUT_CHANNEL = 1
RF_FREQUENCY_GHZ = 1.79
OUTPUT_GAIN = 0.10
SAMPLE_RATE_HZ = 400_000_000.0
GAUSSIAN_DURATION_NS = 30.0
GAUSSIAN_FWHM_NS = 15.0
GAUSSIAN_AMPLITUDE = 0.10
WAVE_SESSION = 1
UDP_TIMEOUT_S = 2.0
UDP_RETRIES = 3
POLL_INTERVAL_S = 0.02
WAIT_TRIGGER_TIMEOUT_S = 30.0
PLAYING_TIMEOUT_S = 10.0


def make_gaussian_waveform() -> np.ndarray:
    """Return little-endian int16 interleaved IQ samples for a small pulse."""

    sample_count = math.ceil(GAUSSIAN_DURATION_NS * 1e-9 * SAMPLE_RATE_HZ)
    time_ns = np.arange(sample_count, dtype=np.float64) / SAMPLE_RATE_HZ * 1e9
    center_ns = (sample_count - 1) / SAMPLE_RATE_HZ * 0.5e9
    sigma_ns = GAUSSIAN_FWHM_NS / (2.0 * math.sqrt(2.0 * math.log(2.0)))
    envelope = np.exp(-0.5 * ((time_ns - center_ns) / sigma_ns) ** 2)
    envelope *= GAUSSIAN_AMPLITUDE * 32767.0
    waveform = np.zeros(sample_count * 2, dtype="<i2")
    waveform[0::2] = np.rint(envelope).astype("<i2")
    return waveform


def wait_for_state(device: Dr47Device, expected: PlaybackState, timeout_s: float) -> None:
    deadline = time.monotonic() + timeout_s
    last = None
    while time.monotonic() < deadline:
        snapshot = device.waveform_status(session=WAVE_SESSION)
        last = snapshot.get("state")
        if last == expected.value:
            return
        time.sleep(POLL_INTERVAL_S)
    raise TimeoutError(f"waveform did not reach {expected.value!r}; last state={last!r}")


def run_test() -> None:
    waveform = make_gaussian_waveform()
    device = Dr47Device(
        ip=BOARD_IP,
        port=BOARD_PORT,
        udp_interface=UDP_INTERFACE,
        udp_source_ip=UDP_SOURCE_IP,
        timeout_s=UDP_TIMEOUT_S,
        retries=UDP_RETRIES,
        batch_mode=True,
    )
    session = 0
    try:
        print(f"[1/4] connecting to {BOARD_IP}:{BOARD_PORT}")
        device.connect()
        device.abort()

        print(f"[2/4] configuring CH{OUTPUT_CHANNEL} at {RF_FREQUENCY_GHZ:g} GHz")
        device.set_xy_target_frequency(OUTPUT_CHANNEL, RF_FREQUENCY_GHZ)
        device.set_gain("xy", OUTPUT_CHANNEL, OUTPUT_GAIN, gain_type="norm")
        device.set_qc_on_off("xy", OUTPUT_CHANNEL, "on")
        device.commit()

        print("[3/4] uploading and committing WAVECTR0 waveform")
        result = device.upload_waveforms(
            {OUTPUT_CHANNEL: waveform},
            wave_formats={OUTPUT_CHANNEL: "interleaved_iq"},
            channel_mask=1 << (OUTPUT_CHANNEL - 1),
            loop_count=1,
        )
        session = int(result["session"])
        print(f"    session={session}, descriptor generation={result.get('descriptor')}")
        wait_for_state(device, PlaybackState.WAIT_TRIGGER, WAIT_TRIGGER_TIMEOUT_S)

        print("[4/4] waiting for one external XS19 Trigger")
        wait_for_state(device, PlaybackState.PLAYING, PLAYING_TIMEOUT_S)
        wait_for_state(device, PlaybackState.DONE, PLAYING_TIMEOUT_S)
        print("PASS: CH1 waveform reached RFDC playback after an external Trigger")
    finally:
        if device.connected:
            try:
                device.stop(session=session)
            except DriverError as error:
                print(f"WARN: stop failed during cleanup: {error}")
        device.close()


def main() -> int:
    try:
        run_test()
        return 0
    except (DriverError, RuntimeError, TimeoutError, ValueError) as error:
        print(f"FAIL: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
