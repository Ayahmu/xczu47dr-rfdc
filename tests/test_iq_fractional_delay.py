"""Bit-exact FIR verification using independent full-record NumPy convolution."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
from collections import deque
from pathlib import Path

import numpy as np

from generate_fractional_delay_coeffs import coefficient_table, verilog_rom

ROOT = Path(__file__).resolve().parents[1]
PIPELINE_CYCLES = 7
TAIL_CYCLES = 3


def pack(samples: np.ndarray) -> int:
    return sum((int(value) & 0xFFFF) << (16 * index)
               for index, value in enumerate(samples.reshape(-1)))


def quantize(values: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    magnitude = (np.abs(values) + 32768) // 65536
    rounded = np.where(values < 0, -magnitude, magnitude)
    clipped = (rounded > 32767) | (rounded < -32768)
    return np.clip(rounded, -32768, 32767), clipped


class Vectors:
    def __init__(self, table: np.ndarray):
        self.table = table
        self.rows: list[str] = []
        self.events = 0
        self.clipped_cycles = 0
        self.boundary_polarities: set[int] = set()

    def segment(self, phase: int, shift: int, blocks: list[np.ndarray | None],
                *, configuration: bool = True, drain: bool = True) -> None:
        # Every segment begins with a flushing edge. A nonconfiguration edge
        # exercises clear while retaining the previous phase and integer shift.
        control = (phase << 2) | (shift << 8) | (1 if configuration else 2)
        self.rows.append(f"{control:03x} {0:064x} {0:064x} 0 0")
        self.events += 1
        if drain:
            blocks = blocks + [None] * (TAIL_CYCLES + PIPELINE_CYCLES + 2)
        source = np.concatenate([
            block if block is not None else np.zeros((8, 2), dtype=np.int64)
            for block in blocks
        ])
        padded = np.pad(source, ((shift, 0), (0, 0)))
        # This reference operates on complete sample vectors; it has no RTL
        # lane indexing, history implementation, or adder-tree reproduction.
        convolution = np.stack([
            np.convolve(padded[:, component], self.table[phase])
            for component in (0, 1)
        ], axis=1)
        values, clipped = quantize(convolution)
        outputs = deque([(0, False)] * (PIPELINE_CYCLES - 1))
        valid_pipeline = deque([False] * PIPELINE_CYCLES)
        tail = 0
        for cycle, block in enumerate(blocks):
            source_valid = block is not None
            work_valid = source_valid or tail > 0
            output_block = values[cycle * 8:(cycle + 1) * 8]
            output_clip = bool(clipped[cycle * 8:(cycle + 1) * 8].any())
            outputs.append((pack(output_block), output_clip) if work_valid else (0, False))
            expected, expected_clip = outputs.popleft()
            valid_pipeline.popleft()
            valid_pipeline.append(work_valid)
            tail = TAIL_CYCLES if source_valid else max(0, tail - 1)
            busy = source_valid or tail > 0 or any(valid_pipeline)
            control = (phase << 2) | (shift << 8) | (int(source_valid) << 11)
            data = pack(block) if source_valid else 0
            self.rows.append(
                f"{control:03x} {data:064x} {expected:064x} {int(busy)} {int(expected_clip)}"
            )
            self.clipped_cycles += int(expected_clip)
            if expected_clip:
                for lane in range(16):
                    sample = (expected >> (lane * 16)) & 0xFFFF
                    if sample in (0x7FFF, 0x8000):
                        self.boundary_polarities.add(sample)
        if drain and (busy or expected):
            raise AssertionError("model did not drain")


def generate_vectors() -> Vectors:
    table = coefficient_table()
    vectors = Vectors(table)
    rng = np.random.default_rng(472024)
    for phase in range(64):
        for shift in range(8):
            # A single-word record places nonzero samples at both endpoints;
            # Q has opposite polarity, exposing component/order mistakes.
            impulse = np.zeros((8, 2), dtype=np.int64)
            impulse[0] = (24000, -23000)
            impulse[-1] = (-21000, 22000)
            vectors.segment(phase, shift, [impulse])
            random_blocks = [rng.integers(-29000, 29001, (8, 2), dtype=np.int64)
                             for _ in range(5)]
            vectors.segment(phase, shift, random_blocks)
    # Continuous all-zero valid words still have a lifecycle, despite silence.
    vectors.segment(0, 0, [np.zeros((8, 2), dtype=np.int64)] * 3)
    for phase in range(64):
        # Choose signs from the coefficient kernel so one output reaches the
        # L1 gain bound. Verify both saturation limits without gain attenuation.
        signs = np.where(table[phase][::-1] >= 0, 1, -1)
        maximum = np.stack([np.where(signs > 0, 32767, -32768),
                            np.where(signs > 0, -32768, 32767)], axis=1)
        vectors.segment(phase, 7, [maximum[:8], maximum[8:]])
    # Invalid input is a time interval of zeros, not backpressure. Changing
    # source_valid must neither compress time nor freeze filter history.
    for phase, shift in ((0, 0), (1, 7), (32, 3), (63, 6)):
        first = rng.integers(-20000, 20001, (8, 2), dtype=np.int64)
        last = rng.integers(-20000, 20001, (8, 2), dtype=np.int64)
        vectors.segment(phase, shift, [first, None, None, last, None, first])
        # Abort at every arithmetic stage and during the tail. The next
        # record uses clear alone, retaining the configuration.
        for abort_cycle in range(1, PIPELINE_CYCLES + TAIL_CYCLES + 2):
            vectors.segment(phase, shift, [first] + [None] * (abort_cycle - 1), drain=False)
            vectors.segment(phase, shift, [last], configuration=False)
    if vectors.boundary_polarities != {0x7FFF, 0x8000}:
        raise AssertionError("saturation tests did not cover both polarities")
    return vectors


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, default=ROOT / "work" / "fir-test")
    parser.add_argument("--vectors-only", action="store_true")
    args = parser.parse_args()
    work = args.work_dir.resolve()
    work.mkdir(parents=True, exist_ok=True)
    rom = ROOT / "hardware" / "vivado" / "src" / "iq_fractional_delay_coeffs.v"
    if rom.read_text(encoding="ascii") != verilog_rom(coefficient_table()):
        raise AssertionError("RTL ROM differs from the quantized coefficient generator")
    vectors = generate_vectors()
    vector_path = work / "fir_vectors.txt"
    vector_path.write_text("\n".join(vectors.rows) + "\n", encoding="ascii")
    report = {
        "cycles": len(vectors.rows),
        "segments": vectors.events,
        "phase_shift_combinations": 512,
        "expected_clipped_cycles": vectors.clipped_cycles,
        "pipeline_cycles_to_rfdc_acceptance": PIPELINE_CYCLES,
        "tail_cycles": TAIL_CYCLES,
    }
    if not args.vectors_only:
        if not shutil.which("iverilog") or not shutil.which("vvp"):
            raise SystemExit("iverilog and vvp are required; use --vectors-only for xsim")
        executable = work / "fir_sim"
        subprocess.run([
            "iverilog", "-g2012", "-s", "tb_iq_fractional_delay_8ppc", "-o", str(executable),
            str(rom), str(ROOT / "hardware/vivado/src/iq_fractional_delay_8ppc.v"),
            str(ROOT / "tests/tb_iq_fractional_delay_8ppc.sv"),
        ], check=True)
        subprocess.run(["vvp", str(executable), f"+VECTORS={vector_path.as_posix()}"], check=True)
        report["result"] = "PASS"
    (work / "verification.json").write_text(json.dumps(report, indent=2) + "\n", encoding="ascii")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
