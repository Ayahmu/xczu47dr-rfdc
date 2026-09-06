#!/usr/bin/env python3
"""Test external trigger phase compensation (Scheme B).

This script demonstrates zero-jitter trigger-to-RF timing with an external
trigger source, achieved by measuring the trigger phase at 200 MHz and
compensating with programmable fabric-domain delay.

Expected results:
- ext_trigger_phase_slot shows the measured phase (0-7, representing 0-35 ns in 5ns steps)
- ext_trigger_phase_valid confirms phase measurement is active
- ILA trigger latency spread should be 0 (all triggers land at the same DAC cycle)
- Scope shows stable RF output with no jitter

Hardware setup:
- XS17: 10 MHz reference clock
- XS18: shorted to XS19 (loopback for initial testing)
- XS20: either as SYNC input (normal slave) or as Trigger output (trigout variant)
- CH1: to oscilloscope
- External trigger: 8 ns pulse to XS19 (for final validation)
"""

import os
import sys
import time
from pathlib import Path

# Add software directory to path
repo_root = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(repo_root / "software"))

from dr47.device import RFSoC2Device
from dr47.waveforms import gaussian_complex
from dr47.network import discover_boards


def main():
    board_ip = os.environ.get("RFSOC_BOARD_IP")
    trigger_count = int(os.environ.get("RFSOC_TRIGGER_COUNT", "100"))

    if not board_ip:
        print("Discovering board...")
        boards = discover_boards(
            interface="enp1s0f0",
            source_ip="169.254.250.11",
            source_cidr="169.254.250.11/16",
            broadcast_ip="169.254.255.255",
            port=1234,
        )
        if not boards:
            print("FAIL: no board answered broadcast")
            return 1
        board = boards[0]
        board_ip = board.current_ip
        print(f"Found board at {board_ip} (MAC {board.current_mac}, UID {board.device_uid})")

    print(f"\n=== Phase Compensation Test (Scheme B) ===")
    print(f"Board IP: {board_ip}")
    print(f"Trigger count: {trigger_count}")

    dev = RFSoC2Device(board_ip, port=1234, timeout=2.0)

    # Check capabilities
    caps = dev.get_capabilities()
    print(f"\nCapabilities:")
    print(f"  SYNC IO: {bool(caps.flags & 0x00200000)}")
    print(f"  TRIGGER IO: {bool(caps.flags & 0x00400000)}")
    print(f"  Build profile: {caps.build_profile}")
    print(f"  Build git: {caps.build_git_hash[:8]}")

    # Get initial status
    status = dev.get_status()
    print(f"\nInitial status:")
    print(f"  RFDC ready: {status.rfdc_ready}")
    print(f"  MTS ready: {status.dac_mts_ready}")
    print(f"  NCO sync ready: {status.nco_sync_ready}")
    print(f"  Trigger input count: {status.trigger_input_count}")
    print(f"  Trigger output count: {status.trigger_output_count}")
    print(f"  Phase measurement:")
    print(f"    slot: {status.ext_trigger_phase_slot} (0-7 = 0-35ns in 5ns steps)")
    print(f"    valid: {status.ext_trigger_phase_valid}")

    # Bypass SYNC for direct trigger testing
    print(f"\n=== Bypassing SYNC ===")
    dev.bypass_sync()
    time.sleep(0.5)
    status = dev.get_status()
    print(f"SYNC bypass: {status.sync_bypass}")
    print(f"SYNC ready: {status.sync_link_ready}")

    # Upload a 60 ns Gaussian pulse at 1 GHz to CH1
    print(f"\n=== Uploading waveform ===")
    duration_ns = 60.0
    carrier_freq_hz = 1.0e9
    fs = 400e6  # 400 MS/s complex
    duration_samples = int(duration_ns * 1e-9 * fs)
    # Round up to beat boundary (8 samples per beat)
    duration_samples = ((duration_samples + 7) // 8) * 8

    waveform = gaussian_complex(
        duration_samples=duration_samples,
        carrier_freq_hz=carrier_freq_hz,
        fs=fs,
        fwhm_ns=duration_ns,
        amplitude=0.5,
    )

    print(f"Waveform: {duration_samples} samples, {duration_samples / fs * 1e9:.1f} ns")
    print(f"Carrier: {carrier_freq_hz / 1e9:.3f} GHz")

    dev.upload_waveforms(
        waveforms={1: waveform},
        channel_mask=0x01,  # CH1 only
        loop=False,
    )

    # Arm
    print(f"\n=== Arming ===")
    dev.arm(run_id=1, channel_mask=0x01)
    time.sleep(0.1)
    status = dev.get_status()
    print(f"Armed: {status.armed}")
    print(f"Prepared: {status.prepared}")

    # Trigger loop
    print(f"\n=== Trigger loop ({trigger_count} triggers) ===")
    print(f"Using emit_trigger() for XS18 loopback test")
    print(f"(Replace with external trigger on XS19 for final validation)")

    trigger_input_start = status.trigger_input_count
    trigger_output_start = status.trigger_output_count
    phase_slots_seen = set()

    for i in range(trigger_count):
        dev.emit_trigger()
        time.sleep(0.001)  # 1 ms between triggers

        if (i + 1) % 20 == 0:
            status = dev.get_status()
            if status.ext_trigger_phase_valid:
                phase_slots_seen.add(status.ext_trigger_phase_slot)

            if not status.prepared:
                # Re-upload and re-arm
                dev.upload_waveforms(
                    waveforms={1: waveform},
                    channel_mask=0x01,
                    loop=False,
                )
                dev.arm(run_id=1, channel_mask=0x01)
                time.sleep(0.05)

            if (i + 1) % 100 == 0:
                print(f"  {i + 1}/{trigger_count} triggers sent")

    # Final status
    time.sleep(0.2)
    status = dev.get_status()
    trigger_input_end = status.trigger_input_count
    trigger_output_end = status.trigger_output_count

    print(f"\n=== Results ===")
    print(f"Trigger input count: {trigger_input_start} → {trigger_input_end} "
          f"(Δ = {trigger_input_end - trigger_input_start})")
    print(f"Trigger output count: {trigger_output_start} → {trigger_output_end} "
          f"(Δ = {trigger_output_end - trigger_output_start})")
    print(f"Phase measurement:")
    print(f"  slot: {status.ext_trigger_phase_slot}")
    print(f"  valid: {status.ext_trigger_phase_valid}")
    print(f"  unique slots seen: {sorted(phase_slots_seen)} "
          f"(should vary 0-7 for external trigger)")

    print(f"\nNext steps:")
    print(f"1. Run software/trigger_latency_report.py to check ILA spread")
    print(f"   Expected: spread = 0 (all triggers at same DAC cycle)")
    print(f"2. Check oscilloscope for RF stability")
    print(f"   Expected: no jitter in persistence mode")
    print(f"3. Replace XS18 loopback with real 8ns external trigger on XS19")
    print(f"   Phase slot should vary 0-7, but RF timing stays fixed")

    return 0


if __name__ == "__main__":
    sys.exit(main())
