import importlib.util
import math
import re
import unittest
from pathlib import Path

import test_rtl_sim as simulation

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(all(simulation.vivado_tool(tool) for tool in ("xvlog", "xelab", "xsim")),
                     "Vivado simulator is unavailable")
class TdcIntegrationTests(unittest.TestCase):
    def simulate(self, name, dependencies, expected):
        sources = [ROOT / path for path in dependencies]
        sources += [ROOT / f"hardware/vivado/src/{name}.v", ROOT / f"tests/tb_{name}.sv"]
        simulation.RtlSimulationTests.run_sim(self, f"tb_{name}", sources, expected)

    def test_capture_reference_and_boundaries(self):
        self.simulate("tdc_event_capture", ["tests/tdc_capture_primitives_sim.v"],
                      "PASS: timestamp reference")

    def test_timestamp_scheduling_and_tail(self):
        self.simulate("tdc_compensating_trigger", [], "PASS: full-phase timestamp scheduler")

    def test_trigger_admission_and_sources(self):
        self.simulate("tdc_trigger_request_mux", [], "PASS: slave SYNC gate")

    def test_fifo_read_reset_release(self):
        self.simulate("tdc_async_fifo", [], "PASS: FIFO read admission releases on rd_clk")

    def test_calibration_transaction_protection(self):
        self.simulate("tdc_register_service", [], "PASS: asynchronous CSR completion")

    def test_event_carrier_rotation(self):
        self.simulate("iq_event_phase_rotator", ["hardware/vivado/src/tdc_sincos.v"],
                      "PASS: event-relative NCO correction")

    def test_network_dna_reset_domain(self):
        simulation.RtlSimulationTests.run_sim(self, "tb_network_dna_reset", [
            ROOT / "hardware/vivado/src/network_config_pl.v", ROOT / "tests/tb_network_dna_reset.sv"
        ], "PASS: DNA reset asserts asynchronously")


class TdcGeneratedDataTests(unittest.TestCase):
    def test_placement_is_reproducible(self):
        path = ROOT / "hardware/vivado/scripts/generate_tdc_capture_xdc.py"
        spec = importlib.util.spec_from_file_location("tdc_xdc_generator", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        actual = (ROOT / "hardware/vivado/constraints/tdc_placement.xdc").read_text()
        self.assertEqual(actual, module.generate())

    def test_sine_rom_matches_q16_quarter_wave(self):
        source = (ROOT / "hardware/vivado/src/tdc_sincos.v").read_text()
        values = {int(index): int(value) for index, value in re.findall(r"lut\[(\d+)\] = 18'd(\d+);", source)}
        expected = {index: math.floor(math.sin(index * math.pi / 8192) * 65536 + 0.5)
                    for index in range(4097)}
        self.assertEqual(values, expected)
