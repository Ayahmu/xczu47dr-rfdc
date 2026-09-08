#!/usr/bin/env python3
"""Emit literal XDC commands for the carry chain and its sampling flip-flops."""
import argparse
from pathlib import Path


def generate(taps=2048, x=50, first_y=0, hierarchy="top_i/u_tdc_capture"):
    if taps < 16 or taps > 2048 or taps & (taps - 1):
        raise ValueError("taps must be a power of two between 16 and 2048")
    lines = [
        "# TDC carry chain and capture FFs are colocated; implementation-only constraints.",
        f"# Generated for TAPS={taps}, eight capture FFs per CARRY8.",
    ]
    for group in range(taps // 8):
        site = f"SLICE_X{x}Y{first_y + group}"
        carry = f"{hierarchy}/carry_block[{group}].u_carry8"
        lines.append(f"set_property LOC {site} [get_cells -hier -filter {{NAME == {carry}}}]")
        lines.append(f"set_property BEL CARRY8 [get_cells -hier -filter {{NAME == {carry}}}]")
        for bit in range(8):
            sample = f"{hierarchy}/sample_bit[{group * 8 + bit}].u_sample_ff"
            lines.append(f"set_property LOC {site} [get_cells -hier -filter {{NAME == {sample}}}]")
            lines.append(f"set_property BEL {'ABCDEFGH'[bit]}FF [get_cells -hier -filter {{NAME == {sample}}}]")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--taps", type=int, default=2048)
    parser.add_argument("--x", type=int, default=50)
    parser.add_argument("--first-y", type=int, default=0)
    parser.add_argument("--hierarchy", default="top_i/u_tdc_capture")
    args = parser.parse_args()
    args.output.write_text(generate(args.taps, args.x, args.first_y, args.hierarchy), encoding="ascii")
