"""Board-level slave synchronization-mode acceptance test.

This test is deliberately specific to the current single-board lab setup:
XS17 receives 10 MHz, XS20 is open, and XS18 is cabled to XS19.  It proves
that an external-mode slave rejects local and cable Trigger events until the
operator explicitly calls ``bypass_sync()``.  It does not claim any RF
frequency or amplitude measurement; those require an instrument measurement.

Run after programming the formal slave bitstream and its matching firmware:

    PYTHONPATH=software python -m dr47.hardware_sync_mode_test
"""

from __future__ import annotations

import time

import numpy as np

from .capabilities import PlaybackState
from .device import Dr47Device
from .errors import DeviceStatusError, DriverError


BOARD_IP = "169.254.32.1"
BOARD_PORT = 1234
UDP_INTERFACE = "enp225s0f1"
UDP_SOURCE_IP = "169.254.250.11"


def _status(device: Dr47Device, label: str):
    status = device.status(refresh=True)
    capabilities = status.capabilities
    print(
        f"{label}: state={status.state.value}, role={capabilities.sync_role}, "
        f"mode={capabilities.sync_mode}, seen={capabilities.sync_seen}, "
        f"ready={capabilities.sync_link_ready}, "
        f"trigger(in/accepted/out)="
        f"{capabilities.trigger_input_count}/"
        f"{capabilities.trigger_accepted_count}/"
        f"{capabilities.trigger_output_count}"
    )
    return status


def _prepare(device: Dr47Device) -> None:
    """Configure CH1, arm it, and wait for the real DAC PREPARED state."""

    # Keep more than the DMA/FIFO loop watermarks in the record. A 512-byte
    # frame is valid for a one-shot test but is too short to demonstrate the
    # continuous RUNNING state used by this acceptance test.
    iq = np.zeros(32768, dtype="<i2")
    iq[::2] = 4096
    device.set_xy_nco_frequency(1, 0.1)
    device.set_gain("xy", 1, 0.2, gain_type="norm")
    device.set_qc_on_off("xy", 1, "on")
    device.commit()
    device.upload_waveforms(
        {1: iq},
        wave_formats={1: "interleaved_iq"},
        auto_start=False,
        loop=True,
        channel_delays={1: 0},
        instruction_repeats=3,
    )
    device.arm(channel_mask=0x01)
    _wait_for_state(device, PlaybackState.PREPARED, "DAC prepare after ARM")


def _wait_for_state(
    device: Dr47Device,
    expected: PlaybackState,
    label: str,
    timeout_s: float = 3.0,
) -> None:
    """Wait for a board-reported state instead of trusting the driver's ACK cache."""

    deadline = time.monotonic() + timeout_s
    last = None
    while time.monotonic() < deadline:
        last = device.status(refresh=True)
        if last.state is expected:
            return
        time.sleep(0.02)
    actual = "unknown" if last is None else last.state.value
    raise AssertionError(f"{label} timed out: expected {expected.value}, got {actual}")


def _require_idle(device: Dr47Device, label: str) -> None:
    status = _status(device, label)
    if status.state is not PlaybackState.IDLE:
        device.abort_mute()
        status = _status(device, f"{label} after ABORT_MUTE")
    if status.state is not PlaybackState.IDLE:
        raise AssertionError(f"board did not reach IDLE before test: {status.state.value}")


def run() -> int:
    device = Dr47Device(
        ip=BOARD_IP,
        port=BOARD_PORT,
        udp_interface=UDP_INTERFACE,
        udp_source_ip=UDP_SOURCE_IP,
        timeout_s=1.0,
        retries=2,
        batch_mode=True,
    )
    try:
        device.connect()
        initial = _status(device, "initial")
        caps = initial.capabilities
        if not caps.rfdc_ready or not caps.dac_mts_ready or not caps.nco_sync_ready:
            raise AssertionError("RFDC, DAC MTS, or NCO SYSREF is not ready")
        if caps.sync_role != "slave":
            raise AssertionError("this test requires custom_xczu47dr_slave bitstream")

        # 1. Strict external mode must reject UDP Trigger when XS20 is open.
        _require_idle(device, "before external-mode test")
        device.require_external_sync()
        external = _status(device, "external mode")
        if external.capabilities.sync_seen or external.capabilities.sync_link_ready:
            raise AssertionError("external mode incorrectly reports a missing XS20 SYNC as ready")
        _prepare(device)
        try:
            device.trigger()
        except DeviceStatusError:
            print("external-mode software TRIGGER correctly rejected")
        else:
            raise AssertionError("external-mode software TRIGGER unexpectedly started playback")
        before = _status(device, "external before XS18 loopback").capabilities
        device.emit_trigger()
        time.sleep(0.1)
        after = _status(device, "external after XS18->XS19").capabilities
        if after.trigger_input_count <= before.trigger_input_count:
            raise AssertionError("XS18->XS19 loopback did not reach the trigger input")
        if after.trigger_accepted_count != before.trigger_accepted_count:
            raise AssertionError("external-mode slave accepted an XS19 trigger without XS20 SYNC")
        if device.status(refresh=False).state not in {PlaybackState.ARMED, PlaybackState.PREPARED}:
            raise AssertionError("external-mode loopback changed playback state")
        device.abort_mute()

        # 2. Bypass is an explicit runtime permission, not a synthetic SYNC.
        device.bypass_sync()
        bypass = _status(device, "bypass mode")
        if bypass.capabilities.sync_seen or not bypass.capabilities.sync_link_ready:
            raise AssertionError("bypass must allow Trigger while keeping sync_seen false")
        _prepare(device)
        device.trigger()
        _wait_for_state(device, PlaybackState.RUNNING, "bypass software TRIGGER")
        _status(device, "bypass after software TRIGGER")
        device.abort_mute()

        _prepare(device)
        before = _status(device, "bypass before XS18 loopback").capabilities
        device.emit_trigger()
        _wait_for_state(device, PlaybackState.RUNNING, "bypass XS18->XS19 Trigger")
        after_status = _status(device, "bypass after XS18->XS19")
        after = after_status.capabilities
        if after_status.state is not PlaybackState.RUNNING:
            raise AssertionError("bypass-mode XS18->XS19 Trigger did not start playback")
        if (after.trigger_input_count <= before.trigger_input_count or
                after.trigger_accepted_count <= before.trigger_accepted_count or
                after.trigger_output_count <= before.trigger_output_count):
            raise AssertionError("bypass loopback counters did not advance as expected")
        device.abort_mute()

        # 3. Changing back to external revokes the authorization immediately.
        device.require_external_sync()
        restored = _status(device, "restored external mode")
        if restored.capabilities.sync_seen or restored.capabilities.sync_link_ready:
            raise AssertionError("returning to external mode did not close the Trigger gate")
        print("PASS: slave external gate, explicit bypass, XS18->XS19 loopback, and restore verified")
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
