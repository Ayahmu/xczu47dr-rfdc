"""ez-Q compatible sequence helpers.

The original ez-Q utility emits four uint16 words per row.  This module keeps
that representation and adds a small, deterministic generator for the
single-board playback path.  Complex conditional/nested programs are rejected
by :func:`waveforms.sequence_to_play_commands` instead of silently changing
their meaning.
"""

from __future__ import annotations

import math
from typing import Iterable, Literal, Sequence

import numpy as np


class PulseWave:
    """Constant-amplitude pulse accepted by the ez-Q ``SequenceGenerator``."""

    def __init__(self, amplitude: float, duration: float) -> None:
        self.frequency = None
        self.amplitude = amplitude
        self.duration = duration
        self.phase = 0.0
        self.sampling_rate = 2e9

    def generate(self) -> np.ndarray:
        count = max(0, int(round(float(self.duration) * self.sampling_rate)))
        return np.full(count, self.amplitude, dtype=np.int32)


class SequenceGenerator:
    """Compatibility implementation of ez-Q's sequence utility.

    ``TriggerSeqGenerate`` returns ``(wave_data, seq_data)`` where ``seq_data``
    has shape ``(n, 4)`` and contains the original ez-Q control words.
    """

    ControlCmd = {
        "LS": 0x1 << 11,
        "LE": 0x2 << 11,
        "DI": 0x0 << 11,
        "TR": 0x8 << 11,
        "DL": 0x4 << 11,
        "CD": 0xC << 11,
        "ST": 0x1 << 15,
    }
    SamplesPerClkDict = {"RI": 1, "RO": 8, "XY": 2, "Z": 4}
    ClkPeriodsDict = {"RI": 3.2, "RO": 4.0, "XY": 4.0, "Z": 4.0}
    MaxDataVolumeDict = {"RI": 1024, "RO": 4096 * 8, "XY": 12500 * 2, "Z": 12500 * 4}
    IntegerTimesDict = {"RI": 5, "RO": 32, "XY": 8, "Z": 16}

    def __init__(
        self,
        channel_type: Literal["XY", "Z", "RI", "RO"] = "",
        time_data: Sequence[float] | None = None,
        event_data: Sequence[object] | None = None,
        mark_data: Sequence[int] | None = None,
        period: float = 0,
        repeat: int = 0,
        delay: float = 0,
        mark_delay: float = 0,
        offset: int = 0,
    ) -> None:
        channel = str(channel_type).upper()
        if channel not in self.SamplesPerClkDict:
            raise ValueError("channel_type must be one of XY, Z, RI or RO")
        self.ChannelType = channel
        self.SamplesPerClk = self.SamplesPerClkDict[channel]
        self.ClkPeriods = self.ClkPeriodsDict[channel]
        self.MaxDataVolume = self.MaxDataVolumeDict[channel]
        self.IntegerTimes = self.IntegerTimesDict[channel]
        self.BitShift = round(math.log2(self.SamplesPerClk))
        self.EventData = list(event_data) if event_data is not None else []
        self.TimeData = list(time_data) if time_data is not None else [0.0] * len(self.EventData)
        self.MarkData = None if mark_data is None else list(mark_data)
        self.TimeDataNs = np.asarray(self.TimeData, dtype=float) * 1e9
        self.PeriodNs = float(period) * 1e9
        self.DelayNs = float(delay) * 1e9
        self.MarkDelay = int(round(float(mark_delay) / 4e-9))
        self.OffSet = int(offset)
        self.Repeat = int(repeat)
        self.MaxRepeat = 0xFFFF
        self.DefaultVolt = 0
        self.WaveData: np.ndarray | None = None
        self.SeqData: np.ndarray | None = None

    def _event_array(self, event: object) -> np.ndarray:
        if isinstance(event, PulseWave):
            values = event.generate()
        else:
            values = np.asarray(event)
        if values.ndim != 1:
            values = values.reshape(-1)
        if self.ChannelType == "RI":
            values = np.repeat(values.astype(np.int32), 5)
        if self.ChannelType in {"XY", "RO"}:
            # ez-Q packed IQ words are conventionally int32.  Preserve values
            # exactly; callers can use interleaved conversion before upload.
            return np.asarray(values, dtype=np.int32)
        return np.asarray(values, dtype=np.int16)

    def _unit_samples(self) -> int:
        return max(1, int(round(16.0 * self.SamplesPerClk / self.ClkPeriods)))

    def TriggerSeqGenerate(self):
        if len(self.TimeData) != len(self.EventData):
            raise ValueError(
                f"The Input Event Data Length:{len(self.EventData)} not matching Input Time Data Length:{len(self.TimeData)}!"
            )
        if self.MarkData is not None and len(self.MarkData) != len(self.EventData):
            raise ValueError(
                f"The Input Event Data Length:{len(self.EventData)} not matching Input Mark Data Length:{len(self.MarkData)}!"
            )
        if not self.EventData:
            raise ValueError("event_data must contain at least one event")
        if self.Repeat <= 0 or self.Repeat > self.MaxRepeat * self.MaxRepeat:
            raise ValueError("repeat must be in the range 1..0xFFFE0001")
        if self.PeriodNs <= 0:
            # The ez-Q implementation permits period=0 for one-shot records.
            self.PeriodNs = max(16.0, float(self.TimeDataNs[-1]) + 16.0)

        unit = self._unit_samples()
        sample_arrays = [self._event_array(event) for event in self.EventData]
        wave_parts: list[np.ndarray] = []
        addresses: list[int] = []
        lengths: list[int] = []
        positions: list[int] = []
        # ez-Q reserves one 16 ns executor unit before the first user event.
        # Keep that historical preamble so generated rows and wave addresses
        # remain compatible with existing scripts.
        wave_parts.append(np.full(self._unit_samples(), self.OffSet, dtype=np.int16 if self.ChannelType == "Z" else np.int32))
        cursor = self._unit_samples()
        relative_positions: list[int] = []
        for index, event in enumerate(sample_arrays):
            # Time values are seconds in the ez-Q API.  The minimum hardware
            # alignment is one 16 ns executor unit.
            requested = int(round(float(self.TimeData[index]) * self.SamplesPerClk / (self.ClkPeriods * 1e-9)))
            requested = max(0, requested)
            relative = (requested // unit) * unit
            target = max(cursor, unit + relative)
            if target > cursor:
                wave_parts.append(np.full(target - cursor, self.OffSet, dtype=event.dtype))
                cursor = target
            elif target < cursor:
                raise ValueError("wave overlap")
            padded_len = int(math.ceil(max(1, event.size) / unit) * unit)
            padded = np.full(padded_len, self.OffSet, dtype=event.dtype)
            padded[: event.size] = event
            addresses.append(cursor // self.SamplesPerClk)
            lengths.append(padded_len // self.SamplesPerClk)
            positions.append(cursor)
            relative_positions.append(relative)
            wave_parts.append(padded)
            cursor += padded_len
        wave_data = np.concatenate(wave_parts) if wave_parts else np.zeros(0, dtype=np.int16)
        if wave_data.size > self.MaxDataVolume:
            raise ValueError(f"The Input Wave Data Length:{wave_data.size} Exceeds The Maximum Support Data Length:{self.MaxDataVolume} !")

        rows: list[list[int]] = []
        idle_units = max(1, unit // self.SamplesPerClk)
        rows.append([0, idle_units, 0, self.ControlCmd["TR"]])
        rows.append([0, idle_units, 0, self.ControlCmd["DL"]])
        delay_cycles = max(0, int(round(self.DelayNs * self.SamplesPerClk / self.ClkPeriods)))
        if delay_cycles:
            rows.append([0, idle_units, delay_cycles, self.ControlCmd["DL"]])
        rows.append([0, idle_units, self.Repeat if self.Repeat <= self.MaxRepeat else self.Repeat & 0xFFFF, self.ControlCmd["LS"]])
        for index, (address, length, position) in enumerate(zip(addresses, lengths, positions)):
            if index:
                gap = max(0, relative_positions[index] - (relative_positions[index - 1] + lengths[index - 1] * self.SamplesPerClk))
                if gap:
                    rows.append([0, idle_units, gap // self.SamplesPerClk, self.ControlCmd["DL"]])
            mark = (1 << 10) if self.MarkData is None or bool(self.MarkData[index]) else 0
            mark |= self.MarkDelay & 0xFF
            rows.append([address, length, 0, self.ControlCmd["DI"] | mark])
        period_samples = int(round(self.PeriodNs * self.SamplesPerClk / self.ClkPeriods))
        period_delay = period_samples - relative_positions[-1] - lengths[-1] * self.SamplesPerClk - 3 * unit
        if period_delay > 0:
            rows.append([0, idle_units, period_delay >> self.BitShift, self.ControlCmd["DL"]])
        rows.append([0, idle_units, 2, self.ControlCmd["LE"]])
        rows.append([0, idle_units, 0, self.ControlCmd["ST"]])
        seq_data = np.asarray(rows, dtype="<u2")
        self.WaveData = np.asarray(wave_data, dtype=np.int16 if self.ChannelType == "Z" else np.int32)
        self.SeqData = seq_data
        return self.WaveData, self.SeqData

    def ContinueSeqGenerate(self):
        wave_data = self._event_array(self.EventData)
        if wave_data.size > self.MaxDataVolume:
            raise ValueError("the length of waveform is too long")
        if self.ChannelType == "XY":
            repeats = 4096
        elif self.ChannelType == "Z":
            repeats = 4096
        else:
            repeats = 256
        length = int(wave_data.size // self.SamplesPerClk)
        seq_data = np.tile(np.asarray([0, length, 0, 0], dtype="<u2"), (repeats, 1))
        self.WaveData = np.asarray(wave_data, dtype=np.int16 if self.ChannelType == "Z" else np.int32)
        self.SeqData = seq_data
        return self.WaveData, self.SeqData


def TriggerSeqGenerate(*args, **kwargs):
    """Generate one ez-Q-compatible trigger sequence.

    This functional spelling is convenient for migration scripts.  It accepts
    either an existing :class:`SequenceGenerator` instance or the constructor
    arguments used to create one.
    """
    if args and isinstance(args[0], SequenceGenerator):
        if len(args) != 1 or kwargs:
            raise TypeError("TriggerSeqGenerate(instance) accepts no additional arguments")
        return args[0].TriggerSeqGenerate()
    return SequenceGenerator(*args, **kwargs).TriggerSeqGenerate()


def make_trigger_sequence(sample_count: int) -> np.ndarray:
    """Return a looping XY sequence that waits for one Trigger per record.

    The returned rows are in the same four-word little-endian representation
    accepted by :meth:`Dr47Device.download_qc_wave_seq`.  It is deliberately
    part of the driver rather than a board-level test helper, so production
    applications and the three hardware tests use exactly the same sequence
    contract.
    """

    count = int(sample_count)
    if not 1 <= count <= 0xFFFF:
        raise ValueError("sample_count must be in 1..65535")
    return np.asarray(
        [
            [0, count, 0, 0x0800],  # LS: infinite top-level loop
            [0, count, 0, 0x4000],  # TR: wait for the next Trigger edge
            [0, count, 0, 0x0000],  # DI: play the uploaded waveform
            [0, count, 0, 0x1000],  # LE: repeat from the loop start
            [0, count, 0, 0x8000],  # ST: stop marker required by ez-Q rows
        ],
        dtype="<u2",
    )


__all__ = ["PulseWave", "SequenceGenerator", "TriggerSeqGenerate", "make_trigger_sequence"]
