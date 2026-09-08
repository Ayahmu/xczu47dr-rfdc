"""Calibration and diagnostics for the eight-channel event compensation path.

Calibration is specific to a placed/routed bitstream and board. Code-density
calibration assumes uniformly distributed excitation phase; the internal PS
clock source is independent of the RF reference, but histogram quality must
still be checked. These checks do not establish analog trigger jitter.
"""
from __future__ import annotations

import operator
import time
from collections.abc import Sequence

import numpy as np

IDENTITY = 0x54444301
CONTROL = 0x0004
STATUS = 0x0008
OFFSET = 0x000C
COMMAND = 0x0058
LUT_BASE = 0x1000
HISTOGRAM_BASE = 0x4000
TAPS = 2048
SAMPLE_PERIOD_PS = 5000
REGISTERS = {
    "status": STATUS, "measured": 0x10, "invalid": 0x14,
    "overflow": 0x18, "bad_code": 0x1C, "phase_10ps": 0x20,
    "raw_tap_and_flags": 0x24, "capture_epoch": 0x28,
    "histogram_samples": 0x2C, "accepted": 0x30,
    "completed": 0x34, "rejected": 0x38, "late": 0x3C,
    "faults": 0x40, "clipped_channels": 0x44,
    "event_state": 0x48, "delay_code": 0x4C, "calibration_revision": 0x54,
}


def validate_table(table: Sequence[int]) -> list[int]:
    if len(table) != TAPS:
        raise ValueError("Calibration must contain exactly 2048 entries")
    values = [operator.index(value) for value in table]
    if any(value < 0 or value > 600 for value in values):
        raise ValueError("Calibration entries must be in 0..600 units of 10 ps")
    if any(right < left for left, right in zip(values, values[1:])):
        raise ValueError("Calibration must be monotonic")
    if values[-1] - values[0] < 400:
        raise ValueError("Calibration does not span the 5 ns sampling window")
    return values


def calibration_from_histogram(histogram: Sequence[int], *, minimum_samples: int = 262144) -> dict:
    if len(histogram) != TAPS:
        raise ValueError("Histogram must contain exactly 2048 bins")
    counts = np.asarray([operator.index(value) for value in histogram], dtype=np.int64)
    if np.any(counts < 0):
        raise ValueError("Histogram counts cannot be negative")
    total = int(counts.sum())
    occupied = int(np.count_nonzero(counts))
    if total < minimum_samples or occupied < 64:
        raise ValueError(f"Insufficient phase coverage: samples={total}, occupied_bins={occupied}")
    widths = counts.astype(np.float64) * SAMPLE_PERIOD_PS / total
    if float(widths.max()) > 100.0:
        raise ValueError("A code-density bin exceeds 100 ps; reject this calibration")
    centers_ps = (np.cumsum(counts, dtype=np.float64) - counts / 2.0) * SAMPLE_PERIOD_PS / total
    table = validate_table(np.rint(centers_ps / 10.0).astype(np.int64).tolist())
    return {
        "schema": 1, "identity": IDENTITY, "units": "10 ps",
        "sample_period_ps": SAMPLE_PERIOD_PS, "tap_count": TAPS,
        "excitation": "independent PS clock; uniform phase assumed",
        "samples": total, "occupied_bins": occupied,
        "largest_bin_ps": float(widths.max()), "table": table,
        "histogram": counts.tolist(),
    }


def check_identity(device) -> None:
    if device.read_tdc_register(0) != IDENTITY:
        raise RuntimeError("This board does not expose the expected TDC register version")


def read_diagnostics(device) -> dict[str, int]:
    return {name: device.read_tdc_register(address) for name, address in REGISTERS.items()}


def _wait_idle(device, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not device.read_tdc_register(STATUS) & (1 << 5):
            return
        time.sleep(0.01)
    raise TimeoutError("TDC configuration requires an idle, unarmed board")


def clear_statistics(device) -> None:
    _wait_idle(device)
    device.write_tdc_register(COMMAND, 1)
    deadline = time.monotonic() + 2.0
    while device.read_tdc_register(STATUS) & (1 << 4):
        if time.monotonic() > deadline:
            raise TimeoutError("Histogram did not clear")
        time.sleep(0.01)


def collect_calibration(device, *, seconds: float = 3.0) -> dict:
    if seconds < 1.0 or not np.isfinite(seconds):
        raise ValueError("Calibration acquisition must last at least one second")
    check_identity(device)
    device.abort_mute()
    _wait_idle(device)
    device.write_tdc_register(CONTROL, 0)
    clear_statistics(device)
    device.write_tdc_register(CONTROL, 2)
    try:
        time.sleep(seconds)
    finally:
        device.write_tdc_register(CONTROL, 0)
    time.sleep(0.001)
    diagnostics = read_diagnostics(device)
    if diagnostics["overflow"]:
        raise RuntimeError("TDC delay line saturated; its sampling window is not fully covered")
    if diagnostics["invalid"] > max(10, diagnostics["measured"] // 100):
        raise RuntimeError("More than 1% of calibration captures were invalid")
    histogram = [device.read_tdc_register(HISTOGRAM_BASE + 4 * index) for index in range(TAPS)]
    result = calibration_from_histogram(histogram)
    result["diagnostics"] = diagnostics
    result["device_uid"] = device.status(refresh=True).capabilities.device_uid
    return result


def load_calibration(device, calibration: dict) -> None:
    check_identity(device)
    if calibration.get("identity") != IDENTITY or calibration.get("units") != "10 ps":
        raise ValueError("Calibration identity or units do not match")
    table = validate_table(calibration["table"])
    actual_uid = device.status(refresh=True).capabilities.device_uid
    expected_uid = calibration.get("device_uid", "")
    if expected_uid and actual_uid != expected_uid:
        raise ValueError("Calibration belongs to a different board")
    _wait_idle(device)
    device.write_tdc_register(CONTROL, 0)
    for index, value in enumerate(table):
        device.write_tdc_register(LUT_BASE + 4 * index, value)
    for index, value in enumerate(table):
        if device.read_tdc_register(LUT_BASE + 4 * index) != value:
            raise RuntimeError(f"Calibration readback failed at tap {index}")
    device.write_tdc_register(COMMAND, 2)
    if not device.read_tdc_register(STATUS) & 2:
        raise RuntimeError("Calibration did not commit")


def enable_compensation(device, *, carrier_phase: bool = True, offset_ps: int = 0) -> None:
    offset = operator.index(offset_ps)
    if offset % 10 or not -19990 <= offset <= 19990:
        raise ValueError("Phase offset must be a 10 ps multiple in -19990..19990 ps")
    _wait_idle(device)
    device.write_tdc_register(OFFSET, (offset // 10) & 0xFFFFFFFF)
    device.write_tdc_register(CONTROL, 5 if carrier_phase else 1)
    if not device.read_tdc_register(STATUS) & 4:
        raise RuntimeError("Compensation did not enable")
