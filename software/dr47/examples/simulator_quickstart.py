#!/usr/bin/env python3
"""Run the recommended playback API without a physical board.

This example is safe to run on any host after installing ``47dr-driver``. It
uses the in-memory simulator to validate waveform generation, RF planning,
finite burst configuration, ARM, software Trigger, status, and cleanup.
"""

from __future__ import annotations

from dr47 import (
    BurstSchedule,
    PlaybackState,
    SimulatedDr47Device,
    make_iq_gaussian_sine_interleaved,
)


# Example configuration. These values do not access real hardware.
RF_FREQUENCY_GHZ = 4.0
SAMPLE_RATE_HZ = 400_000_000.0
GAUSSIAN_DURATION_NS = 40.0
GAUSSIAN_FWHM_NS = 20.0
GAUSSIAN_AMPLITUDE = 20_000
FIRST_DELAY_NS = 20.0
PULSE_INTERVAL_NS = 1000.0
PULSES_PER_TRIGGER = 3


def main() -> int:
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

    with SimulatedDr47Device(sync_role="master", batch_mode=True) as device:
        plan = device.set_xy_target_frequency(1, RF_FREQUENCY_GHZ)
        device.set_gain("xy", 1, 0.7)
        device.set_qc_on_off("xy", 1, "on")
        device.commit()

        playback = device.configure_playback(
            {1: waveform},
            schedule=schedule,
            wave_formats={1: "interleaved_iq"},
            channel_mask=0x01,
        )
        device.arm_playback(channel_mask=playback.channel_mask)
        device.trigger_playback()

        status = device.status(refresh=False)
        if status.state is not PlaybackState.RUNNING:
            raise RuntimeError(f"expected running, got {status.state.value}")

        print(f"driver simulation OK: device={status.capabilities.device_uid}")
        print(
            f"RF target={plan['target_rf_ghz']:g} GHz, "
            f"NCO={plan['nco_ghz']:g} GHz, zone={plan['nyquist_zone']}"
        )
        print(
            "burst: "
            f"delay={playback.schedule.effective_first_delay_ns:g} ns, "
            f"interval={playback.schedule.effective_interval_ns:g} ns, "
            f"pulses={playback.schedule.repetitions}, "
            f"record={playback.record_bytes_per_channel} bytes/channel"
        )
        device.abort_playback()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
