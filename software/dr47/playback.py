"""High-level playback configuration and deterministic burst scheduling."""

from __future__ import annotations

import math
from dataclasses import dataclass

from .errors import ParameterRangeError

AXIS_PERIOD_NS = 20.0
MAX_REPEAT_COUNT = 0xFFFFFFFF


def quantize_axis_cycles(value_ns: float, *, name: str, allow_zero: bool = True) -> tuple[int, float]:
    """Round a requested time upward to the 50 MHz DAC fabric clock."""
    value = float(value_ns)
    if not math.isfinite(value) or value < 0.0 or (not allow_zero and value <= 0.0):
        relation = "non-negative" if allow_zero else "positive"
        raise ParameterRangeError(f"{name} must be a finite {relation} number")
    cycles = int(math.ceil(value / AXIS_PERIOD_NS))
    if not allow_zero:
        cycles = max(1, cycles)
    return cycles, cycles * AXIS_PERIOD_NS


@dataclass(frozen=True)
class BurstSchedule:
    """One common schedule shared by all enabled playback channels."""

    first_delay_ns: float
    interval_ns: float
    repetitions: int
    debug_alternate: bool = False

    def quantized(self) -> "QuantizedBurstSchedule":
        first_cycles, first_ns = quantize_axis_cycles(
            self.first_delay_ns, name="first_delay_ns"
        )
        interval_cycles, interval_ns = quantize_axis_cycles(
            self.interval_ns, name="interval_ns", allow_zero=False
        )
        repetitions = int(self.repetitions)
        if not 1 <= repetitions <= MAX_REPEAT_COUNT:
            raise ParameterRangeError(
                f"repetitions must be in [1, {MAX_REPEAT_COUNT}], got {repetitions}"
            )
        return QuantizedBurstSchedule(
            requested_first_delay_ns=float(self.first_delay_ns),
            requested_interval_ns=float(self.interval_ns),
            effective_first_delay_ns=first_ns,
            effective_interval_ns=interval_ns,
            first_delay_cycles=first_cycles,
            interval_cycles=interval_cycles,
            repetitions=repetitions,
            debug_alternate=bool(self.debug_alternate),
        )


@dataclass(frozen=True)
class QuantizedBurstSchedule:
    requested_first_delay_ns: float
    requested_interval_ns: float
    effective_first_delay_ns: float
    effective_interval_ns: float
    first_delay_cycles: int
    interval_cycles: int
    repetitions: int
    debug_alternate: bool = False

    @property
    def effective_period_ns(self) -> float:
        return self.effective_interval_ns


@dataclass(frozen=True)
class PlaybackConfig:
    schedule: QuantizedBurstSchedule
    channel_mask: int
    record_duration_ns: float
    record_bytes_per_channel: int


__all__ = [
    "AXIS_PERIOD_NS",
    "MAX_REPEAT_COUNT",
    "BurstSchedule",
    "QuantizedBurstSchedule",
    "PlaybackConfig",
    "quantize_axis_cycles",
]
