"""External XS19 -> eight-channel RF timing experiment, using a calibrated bit.

XS17 and the 32 ns external Trigger share a 250 MHz reference. Split Trigger
to XS19 and the oscilloscope trigger input. Observe each DAC channel against
that external edge. This script uploads once, never emits a local Trigger,
and lets FPGA finite-record rearming run. An NPZ may provide ch1..ch8 arrays
of interleaved int16 IQ; otherwise all eight outputs use the Gaussian record.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import time
from pathlib import Path

import numpy as np

from ..device import Dr47Device
from ..tdc import collect_calibration, load_calibration, enable_compensation, read_diagnostics, clear_statistics
from ._common import make_gaussian_record


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ip", default=os.environ.get("RFSOC_BOARD_IP", "169.254.100.101"))
    parser.add_argument("--interface", default=os.environ.get("RFSOC_UDP_INTERFACE", "enp1s0f0"))
    parser.add_argument("--source-ip", default=os.environ.get("RFSOC_CONTROL_SOURCE_IP", "169.254.250.11"))
    parser.add_argument("--bit", type=Path, required=True, help="The bitstream already programmed on this board")
    parser.add_argument("--calibration", type=Path, required=True)
    parser.add_argument("--calibrate", action="store_true")
    parser.add_argument("--calibrate-only", action="store_true")
    parser.add_argument("--calibration-seconds", type=float, default=3.0)
    parser.add_argument("--baseline", action="store_true", help="Disable compensation for the comparison run")
    parser.add_argument("--seconds", type=float, default=30.0)
    parser.add_argument("--nco-ghz", type=float, nargs=8, default=[0.5] * 8)
    parser.add_argument("--waveforms", type=Path)
    args = parser.parse_args(argv)
    bit_hash = hashlib.sha256(args.bit.read_bytes()).hexdigest()
    device = Dr47Device(ip=args.ip, port=1234, udp_interface=args.interface,
                        udp_source_ip=args.source_ip, timeout_s=2.0, retries=2)
    try:
        device.connect()
        device.abort_mute()
        device.bypass_sync()
        if args.calibrate or args.calibrate_only:
            calibration = collect_calibration(device, seconds=args.calibration_seconds)
            calibration["bit_sha256"] = bit_hash
            args.calibration.parent.mkdir(parents=True, exist_ok=True)
            args.calibration.write_text(json.dumps(calibration, indent=2) + "\n", encoding="utf-8")
        else:
            calibration = json.loads(args.calibration.read_text(encoding="utf-8"))
        if calibration.get("bit_sha256") != bit_hash:
            raise ValueError("Calibration does not match the specified bitstream")
        load_calibration(device, calibration)
        if args.calibrate_only:
            print(json.dumps({key: value for key, value in calibration.items()
                              if key not in {"table", "histogram"}}, indent=2))
            return 0
        clear_statistics(device)
        device.apply_rfdc_config(nco_ghz=args.nco_ghz, nyquist_zone=[1] * 8,
                                phase_deg=[0.0] * 8, output_current_ma=[20.0] * 8,
                                channel_mask=0xFF)
        if args.baseline:
            device.write_tdc_register(4, 0)
        else:
            enable_compensation(device, carrier_phase=True)
        if args.waveforms:
            with np.load(args.waveforms, allow_pickle=False) as archive:
                waves = {channel: archive[f"ch{channel}"].copy() for channel in range(1, 9)}
        else:
            wave = make_gaussian_record(duration_ns=60.0, delay_ns=100.0,
                                        record_duration_ns=10000.0, amplitude=0.5)
            waves = {channel: wave for channel in range(1, 9)}
        device.upload_waveforms(waves, wave_formats={channel: "interleaved_iq" for channel in waves},
                                auto_start=False, loop=False)
        device.arm(channel_mask=0xFF)
        deadline = time.monotonic() + args.seconds
        while time.monotonic() < deadline:
            diagnostics = read_diagnostics(device)
            print(json.dumps(diagnostics, sort_keys=True), flush=True)
            if diagnostics["faults"]:
                raise RuntimeError("The compensated playback path reported a fault")
            time.sleep(0.5)
        device.abort_mute()
        time.sleep(0.02)
        diagnostics = read_diagnostics(device)
        print(json.dumps(diagnostics, indent=2))
        if not args.baseline and not diagnostics["accepted"]:
            raise RuntimeError("No external trigger was accepted")
        if diagnostics["clipped_channels"]:
            raise RuntimeError("Clipping occurred; lower uploaded IQ amplitude before timing measurement")
        print("Digital run complete. Evaluate the analog delay distribution from oscilloscope acquisitions.")
        return 0
    finally:
        try:
            device.abort_mute()
        finally:
            device.close()


if __name__ == "__main__":
    raise SystemExit(main())
