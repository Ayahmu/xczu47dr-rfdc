"""Plot digital-model limits; this is not an oscilloscope measurement."""
import argparse
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from scipy.signal import group_delay

from generate_fractional_delay_coeffs import coefficient_table


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    phase_units = np.arange(2000)
    codes = (phase_units * 64 + 125) // 250
    residual_ps = codes * 2500 / 64 - phase_units * 10
    frequencies = np.linspace(0, 190e6, 761)
    worst_error = np.zeros_like(frequencies)
    for phase, coefficients in enumerate(coefficient_table()):
        _, delay = group_delay((coefficients / 65536, [1.0]), w=2 * np.pi * frequencies / 400e6)
        worst_error = np.maximum(worst_error, np.abs(delay - (7 + phase / 64)) * 2500)
    plt.rcParams.update({"font.size": 10, "axes.spines.top": False, "axes.spines.right": False})
    fig, axes = plt.subplots(2, 1, figsize=(10, 7), layout="constrained")
    axes[0].plot(phase_units / 100, residual_ps, color="#00796b", linewidth=0.8)
    axes[0].set(xlabel="Trigger phase within the 20 ns DAC beat (ns)",
                ylabel="Quantization residual (ps)", ylim=(-25, 25),
                title=f"64-phase delay quantization: {np.ptp(residual_ps):.2f} ps peak-to-peak")
    axes[0].grid(alpha=0.2)
    axes[1].semilogy(frequencies / 1e6, np.maximum(worst_error, 0.01), color="#242424", linewidth=1.5)
    axes[1].axhline(200, color="#b7193f", linestyle="--", label="200 ps reference")
    axes[1].axvline(100, color="#00796b", linestyle=":", label="100 MHz characterized baseband")
    axes[1].set(xlabel="IQ baseband frequency magnitude (MHz)",
                ylabel="Worst group-delay error (ps)",
                title="Quantized 16-tap FIR: worst absolute error across 64 phases")
    axes[1].grid(alpha=0.2, which="both")
    axes[1].legend(loc="upper left")
    fig.suptitle("TDC compensation: digital-model limits", fontsize=16)
    fig.text(0.5, -0.025, "Models exclude TDC calibration error, clock noise, RFDC/analog effects and instrument noise.",
             ha="center", fontsize=9, color="#555555")
    fig.savefig(args.output, dpi=160, bbox_inches="tight", facecolor="white")
    plt.close(fig)


if __name__ == "__main__":
    main()
