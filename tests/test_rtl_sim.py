import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(all(shutil.which(tool) for tool in ("xvlog", "xelab", "xsim")), "Vivado simulator is unavailable")
class RtlSimulationTests(unittest.TestCase):
    def run_sim(self, top: str, sources: list[Path], expected: str) -> None:
        with tempfile.TemporaryDirectory(prefix=f"{top}-") as temp_dir:
            workdir = Path(temp_dir)
            subprocess.run(
                ["xvlog", "-sv", *(str(source) for source in sources)],
                cwd=workdir,
                check=True,
                text=True,
                capture_output=True,
            )
            subprocess.run(
                ["xelab", top, "-s", "sim"],
                cwd=workdir,
                check=True,
                text=True,
                capture_output=True,
            )
            result = subprocess.run(
                ["xsim", "sim", "-runall"],
                cwd=workdir,
                check=True,
                text=True,
                capture_output=True,
            )
            self.assertIn(expected, result.stdout)

    def test_udp_writer_legacy_and_bulk_protocol(self):
        self.run_sim(
            "tb_udp_waveform_ddr_writer_alignment",
            [
                ROOT / "hardware/vivado/src/udp_waveform_ddr_writer.v",
                ROOT / "tests/tb_udp_waveform_ddr_writer_alignment.sv",
            ],
            "PASS: UDP DDR writer preserves legacy writes and bulk sequential writes",
        )

    def test_dac_play_completion_and_underflow_counters(self):
        self.run_sim(
            "tb_dac_play_ctrl",
            [
                ROOT / "hardware/vivado/src/dac_play_ctrl.v",
                ROOT / "tests/tb_dac_play_ctrl.sv",
            ],
            "PASS: dac_play_ctrl starts short frames and reports completion/fire/underflow debug state",
        )

    def test_interleaved_executor_retains_33bit_total_length(self):
        self.run_sim(
            "tb_waveform_interleaved_rearm",
            [
                ROOT / "tests/axis_data_fifo_1_sim.sv",
                ROOT / "hardware/vivado/src/waveform_interleaved_system_top.v",
                ROOT / "tests/tb_waveform_interleaved_rearm.sv",
            ],
            "PASS: interleaved executor accepts a new frame after stale WAITTRIG",
        )


if __name__ == "__main__":
    unittest.main()
