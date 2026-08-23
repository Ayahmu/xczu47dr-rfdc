"""Board-level master local-trigger acceptance test.

This test targets the current single-board setup: XS17 receives 10 MHz, XS20
has no peer, and XS18 is connected to XS19.  It proves that the formal master
bitstream may play locally without calling ``sync()`` first.  The final sync
request checks the control path only; without an XS20 measurement instrument or
peer it is not evidence of a physical SYNC pulse.

Run after programming the formal master bitstream and matching firmware:

    PYTHONPATH=software python -m dr47.hardware_master_local_test
"""

from __future__ import annotations

import time

import numpy as np

from .capabilities import PlaybackState
from .device import Dr47Device
from .errors import DriverError


BOARD_IP = "169.254.32.1"
BOARD_PORT = 1234
UDP_INTERFACE = "enp225s0f1"
UDP_SOURCE_IP = "169.254.250.11"


def _status(device: Dr47Device, label: str):
    status = device.status(refresh=True)
    caps = status.capabilities
    print(
        f"{label}: state={status.state.value}, role={caps.sync_role}, "
        f"mode={caps.sync_mode}, seen={caps.sync_seen}, ready={caps.sync_link_ready}, "
        f"trigger(in/accepted/out)={caps.trigger_input_count}/"
        f"{caps.trigger_accepted_count}/{caps.trigger_output_count}"
    )
    return status


def _wait_for_state(device: Dr47Device, expected: PlaybackState, label: str) -> None:
    deadline = time.monotonic() + 3.0
    last = None
    while time.monotonic() < deadline:
        last = device.status(refresh=True)
        if last.state is expected:
            return
        time.sleep(0.02)
    actual = "unknown" if last is None else last.state.value
    raise AssertionError(f"{label} timed out: expected {expected.value}, got {actual}")


def _prepare(device: Dr47Device) -> None:
    """Upload a sustainable looping record and wait for real DAC prepare."""

    # 64 KiB exceeds the loop refill watermark; a tiny frame can underflow and
    # leave RUNNING before this black-box test has time to observe it.
    iq = np.zeros(32768, dtype="<i2")
    iq[::2] = 4096
    device.set_xy_nco_frequency(1, 0.1)
    device.set_gain("xy", 1, 0.2, gain_type="norm")
    device.set_qc_on_off("xy", 1, "on")
    device.commit()
    device.upload_waveforms(
        {1: iq}, wave_formats={1: "interleaved_iq"}, auto_start=False,
        loop=True, channel_delays={1: 0}, instruction_repeats=3,
    )
    device.arm(channel_mask=0x01)
    _wait_for_state(device, PlaybackState.PREPARED, "DAC prepare after ARM")


def _require_idle(device: Dr47Device) -> None:
    if device.status(refresh=True).state is not PlaybackState.IDLE:
        device.abort_mute()
    if device.status(refresh=True).state is not PlaybackState.IDLE:
        raise AssertionError("board did not reach IDLE before test")


def run() -> int:
    device = Dr47Device(
        ip=BOARD_IP, port=BOARD_PORT, udp_interface=UDP_INTERFACE,
        udp_source_ip=UDP_SOURCE_IP, timeout_s=1.0, retries=2, batch_mode=True,
    )
    try:
        device.connect()
        initial = _status(device, "initial")
        caps = initial.capabilities
        if not (caps.rfdc_ready and caps.dac_mts_ready and caps.nco_sync_ready):
            raise AssertionError("RFDC, DAC MTS, or NCO SYSREF is not ready")
        if caps.sync_role != "master":
            raise AssertionError("this test requires custom_xczu47dr_master")
        if not caps.sync_link_ready:
            raise AssertionError("master must allow local Trigger before sync()")

        # 1. The master must accept an ordinary software trigger before sync().
        _require_idle(device)
        _prepare(device)
        device.trigger()
        _wait_for_state(device, PlaybackState.RUNNING, "master software TRIGGER")
        _status(device, "master after software TRIGGER without sync")
        device.abort_mute()

        # 2. XS18 output reaches XS19 input through the installed loopback.
        _prepare(device)
        before = _status(device, "master before XS18->XS19 loopback").capabilities
        device.emit_trigger()
        _wait_for_state(device, PlaybackState.RUNNING, "master XS18->XS19 Trigger")
        after = _status(device, "master after XS18->XS19 loopback").capabilities
        if (after.trigger_input_count <= before.trigger_input_count or
                after.trigger_accepted_count <= before.trigger_accepted_count or
                after.trigger_output_count <= before.trigger_output_count):
            raise AssertionError("master XS18->XS19 loopback counters did not advance")
        device.abort_mute()

        # 3. The protocol accepts an explicit master SYNC request.  XS20 has no
        # peer here, so this validates only the control command, not its signal.
        device.sync(epoch=1)
        _status(device, "master after sync control request")
        print("PASS: master local software Trigger, XS18->XS19 loopback, and sync control verified")
        return 0
    except (DriverError, AssertionError) as error:
        print(f"FAIL: {type(error).__name__}: {error}")
        return 2
    finally:
        try:
            if device.connected:
                device.abort_mute()
        except DriverError:
            pass
        device.close()


if __name__ == "__main__":
    raise SystemExit(run())
