#!/usr/bin/env python3
"""Configure CH1/CH2 and start one finite burst with a software Trigger.

Connections:

    XS17 <- 250 MHz reference
    XS18, XS19, XS20 disconnected
    CH1/CH2 -> oscilloscope or 50 ohm loads

This sample expects a slave-compatible bitstream and explicitly enables
``bypass`` because no XS20 SYNC pulse is provided. Edit the constants below,
then run the file without command-line arguments.
"""

from __future__ import annotations

import time

from dr47 import (
    BurstSchedule,
    Dr47Device,
    DriverError,
    PlaybackState,
    make_iq_gaussian_sine_interleaved,
)


# =============================================================================
# User configuration
# =============================================================================

BOARD_IP = "169.254.149.60"
BOARD_PORT = 1234
UDP_INTERFACE = "enp1s0f0"
UDP_SOURCE_IP = "169.254.250.11"

OUTPUT_CHANNELS = (1, 2)
RF_FREQUENCY_GHZ = 4.9385
OUTPUT_GAIN = 0.7

SAMPLE_RATE_HZ = 400_000_000.0
GAUSSIAN_DURATION_NS = 40.0
GAUSSIAN_FWHM_NS = 20.0
GAUSSIAN_AMPLITUDE = 22_000

FIRST_DELAY_NS = 20.0
PULSE_INTERVAL_NS = 1000.0
PULSES_PER_TRIGGER = 3

UDP_TIMEOUT_S = 2.0
UDP_RETRIES = 3
RFDC_READY_TIMEOUT_S = 30.0
PLAYBACK_TIMEOUT_S = 10.0
POLL_INTERVAL_S = 0.02


CHANNEL_MASK = sum(1 << (channel - 1) for channel in OUTPUT_CHANNELS)


def print_upload_progress(sent_packets: int, total_packets: int) -> None:
    """Render a single-line upload progress indicator."""

    if total_packets <= 0:
        return
    percent = min(100, round(sent_packets * 100 / total_packets))
    print(
        f"\r    upload {percent:3d}% "
        f"({sent_packets}/{total_packets} waveform packets)",
        end="\n" if sent_packets >= total_packets else "",
        flush=True,
    )


def wait_rfdc_ready(device: Dr47Device) -> None:
    deadline = time.monotonic() + RFDC_READY_TIMEOUT_S
    while time.monotonic() < deadline:
        caps = device.status(refresh=True).capabilities
        if caps.dac_mts_failed:
            raise RuntimeError(f"DAC MTS failed: 0x{caps.dac_mts_error:04X}")
        if caps.rfdc_ready and caps.dac_mts_ready and caps.nco_sync_ready:
            return
        time.sleep(POLL_INTERVAL_S)
    raise TimeoutError("RFDC/DAC MTS/NCO did not become ready")


def wait_state(device: Dr47Device, expected: PlaybackState, label: str) -> None:
    deadline = time.monotonic() + PLAYBACK_TIMEOUT_S
    while time.monotonic() < deadline:
        actual = device.status(refresh=True).state
        if actual is expected:
            return
        time.sleep(POLL_INTERVAL_S)
    raise TimeoutError(f"{label}: expected {expected.value}")


def run() -> int:
    waveform = make_iq_gaussian_sine_interleaved(
        frequency_hz=0.0,
        phase_rad=0.0,
        amplitude=GAUSSIAN_AMPLITUDE,
        sample_rate_hz=SAMPLE_RATE_HZ,
        duration_s=GAUSSIAN_DURATION_NS * 1e-9,
        fwhm_s=GAUSSIAN_FWHM_NS * 1e-9,
    )
    schedule = BurstSchedule(
        first_delay_ns=FIRST_DELAY_NS,
        interval_ns=PULSE_INTERVAL_NS,
        repetitions=PULSES_PER_TRIGGER,
    )
    device = Dr47Device(
        ip=BOARD_IP,
        port=BOARD_PORT,
        udp_interface=UDP_INTERFACE,
        udp_source_ip=UDP_SOURCE_IP,
        timeout_s=UDP_TIMEOUT_S,
        retries=UDP_RETRIES,
        batch_mode=True,
        sync_role="slave",
    )

    try:
        print(f"[1/5] connect {BOARD_IP}:{BOARD_PORT}")
        device.connect()
        device.abort_playback()
        wait_rfdc_ready(device)

        print("[2/5] enable slave bypass mode")
        device.bypass_sync()

        print(f"[3/5] configure channels {OUTPUT_CHANNELS}")
        for channel in OUTPUT_CHANNELS:
            device.set_xy_target_frequency(channel, RF_FREQUENCY_GHZ)
            device.set_gain("xy", channel, OUTPUT_GAIN)
            device.set_qc_on_off("xy", channel, "on")
        device.commit()

        print("[4/5] upload one waveform record and ARM")
        playback = device.configure_playback(
            {channel: waveform for channel in OUTPUT_CHANNELS},
            schedule=schedule,
            wave_formats={channel: "interleaved_iq" for channel in OUTPUT_CHANNELS},
            channel_mask=CHANNEL_MASK,
            bulk_upload=True,
            progress_callback=print_upload_progress,
        )
        device.arm_playback(channel_mask=playback.channel_mask)
        wait_state(device, PlaybackState.PREPARED, "after ARM")

        print("[5/5] send one software Trigger")
        device.trigger_playback()
        wait_state(device, PlaybackState.PREPARED, "after finite burst")
        print(
            "PASS: "
            f"delay={playback.schedule.effective_first_delay_ns:g} ns, "
            f"interval={playback.schedule.effective_interval_ns:g} ns, "
            f"pulses={playback.schedule.repetitions}"
        )
        return 0
    except (DriverError, RuntimeError, TimeoutError, ValueError) as error:
        print(f"FAIL: {error}")
        return 1
    finally:
        if device.connected:
            try:
                device.abort_playback()
            except DriverError as error:
                print(f"WARN: cleanup failed: {error}")
        device.close()


if __name__ == "__main__":
    raise SystemExit(run())
