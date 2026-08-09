import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def vivado_tool(name: str) -> str | None:
    return shutil.which(name)


@unittest.skipUnless(
    all(vivado_tool(tool) for tool in ("xvhdl", "xelab", "xsim")),
    "Vivado simulator is unavailable",
)
class Hmc7044RtlSimulationTests(unittest.TestCase):
    def test_spi_autotune_settle_and_restart_sequence(self):
        with tempfile.TemporaryDirectory(prefix="hmc7044-sim-") as temp_dir:
            commands = (
                [
                    vivado_tool("xvhdl"),
                    "--2008",
                    str(ROOT / "hardware/vivado/src/hmc7044.vhd"),
                    str(ROOT / "tests/tb_hmc7044.vhd"),
                ],
                [vivado_tool("xelab"), "tb_hmc7044", "-s", "sim"],
                [vivado_tool("xsim"), "sim", "-runall"],
            )
            outputs = []
            for command in commands:
                result = subprocess.run(
                    command,
                    cwd=temp_dir,
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=60,
                )
                outputs.append(result.stdout + result.stderr)
                self.assertEqual(result.returncode, 0, "\n".join(outputs))

            self.assertIn("HMC7044 SPI autotune sequence passed", outputs[-1])
