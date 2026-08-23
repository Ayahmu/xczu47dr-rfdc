import shutil
import subprocess
import tempfile
import os
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VIVADO_BIN = Path(os.environ.get("VIVADO_BIN", "/tools/Xilinx/Vivado/2024.2/bin"))


def vivado_tool(name: str) -> str | None:
    return shutil.which(name) or (str(VIVADO_BIN / name) if (VIVADO_BIN / name).is_file() else None)


@unittest.skipUnless(all(vivado_tool(tool) for tool in ("xvlog", "xelab", "xsim")), "Vivado simulator is unavailable")
class RtlSimulationTests(unittest.TestCase):
    def run_sim(self, top: str, sources: list[Path], expected: str) -> None:
        with tempfile.TemporaryDirectory(prefix=f"{top}-") as temp_dir:
            workdir = Path(temp_dir)
            subprocess.run(
                [vivado_tool("xvlog"), "-sv", *(str(source) for source in sources)],
                cwd=workdir,
                check=True,
                text=True,
                capture_output=True,
            )
            subprocess.run(
                [vivado_tool("xelab"), top, "-s", "sim"],
                cwd=workdir,
                check=True,
                text=True,
                capture_output=True,
            )
            result = subprocess.run(
                [vivado_tool("xsim"), "sim", "-runall"],
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

    def test_udp_writer_routes_rvctrl_packets(self):
        self.run_sim(
            "tb_udp_rvctrl_protocol",
            [
                ROOT / "hardware/vivado/src/udp_waveform_ddr_writer.v",
                ROOT / "tests/tb_udp_rvctrl_protocol.sv",
            ],
            "PASS: RVCTRL0/RVCTRL1/RFCTRL2 packets route to the PL control path and framed UDP instructions",
        )

    def test_udp_writer_resets_at_packet_boundary(self):
        self.run_sim(
            "tb_udp_waveform_packet_boundary",
            [
                ROOT / "hardware/vivado/src/udp_waveform_ddr_writer.v",
                ROOT / "tests/tb_udp_waveform_packet_boundary.sv",
            ],
            "PASS: UDP packet boundary terminates incomplete bulk parsing",
        )

    def test_udp_writer_drops_oversized_bulk_packet(self):
        self.run_sim(
            "tb_udp_waveform_bulk_limit",
            [
                ROOT / "hardware/vivado/src/udp_waveform_ddr_writer.v",
                ROOT / "tests/tb_udp_waveform_bulk_limit.sv",
            ],
            "PASS: UDP writer drops oversized bulk packets at the UDP boundary",
        )

    def test_rfctrl2_status_crosses_writer_and_control_response_path(self):
        self.run_sim(
            "tb_rfctrl2_control_path",
            [
                ROOT / "hardware/vivado/src/udp_waveform_ddr_writer.v",
                ROOT / "hardware/vivado/src/pl_riscv_control_v1.v",
                ROOT / "tests/tb_rfctrl2_control_path.sv",
            ],
            "PASS: full RFCTRL2 STATUS payload crosses the UDP writer and PL control response path",
        )

    def test_rfctrl2_udp_response_targets_requester_and_handles_backpressure(self):
        self.run_sim(
            "tb_rfctrl2_udp_response_tx",
            [
                ROOT / "hardware/vivado/src/udp/rfctrl2_udp_response_tx.v",
                ROOT / "tests/tb_rfctrl2_udp_response_tx.sv",
            ],
            "PASS: RFCTRL2 UDP response TX locks the exact requester and honors AXIS backpressure",
        )

    def test_pl_riscv_control_v1_emits_play_and_trigger(self):
        self.run_sim(
            "tb_pl_riscv_control_v1",
            [
                ROOT / "hardware/vivado/src/pl_riscv_control_v1.v",
                ROOT / "tests/tb_pl_riscv_control_v1.sv",
            ],
            "PASS: PL control shim emits legacy commands plus RFCTRL2 ARM, RFDC_APPLY, and SYNC_EPOCH",
        )

    def test_dac_play_completion_and_underflow_counters(self):
        self.run_sim(
            "tb_dac_play_ctrl",
            [
                ROOT / "hardware/vivado/src/dac_play_ctrl.v",
                ROOT / "tests/tb_dac_play_ctrl.sv",
            ],
            "PASS: dac_play_ctrl preserves legacy startup and loops from refill-safe FIFO state",
        )

    def test_rfctrl2_playback_controller_is_single_board(self):
        self.run_sim(
            "tb_rfctrl2_playback_controller",
            [
                ROOT / "hardware/vivado/src/rfctrl2_playback_controller.v",
                ROOT / "tests/tb_rfctrl2_playback_controller.sv",
            ],
            "PASS: RFCTRL2 single-board playback CDC arms, triggers, and aborts without board sync",
        )

    def test_pl_rfdc_runtime_controller_closes_the_axi_readback_loop(self):
        self.run_sim(
            "tb_rfdc_runtime_config_pl",
            [
                ROOT / "hardware/vivado/src/rfdc_runtime_config_pl.v",
                ROOT / "tests/tb_rfdc_runtime_config_pl.sv",
            ],
            "PASS: PL RFDC controller stages NCO RTS, probes readiness, validates VOP/Nyquist, caches retries, and reports failures",
        )

    def test_rfdc_nco_rts_bridge_commits_all_tiles_on_one_edge(self):
        self.run_sim(
            "tb_rfdc_nco_rts_bridge",
            [
                ROOT / "hardware/vivado/src/rfdc_nco_rts_bridge.v",
                ROOT / "tests/tb_rfdc_nco_rts_bridge.sv",
            ],
            "PASS: NCO RTS bridge gates SYSREF and commits enabled channels across four tiles",
        )

    def test_sync_role_switch_generates_master_and_slave_paths(self):
        self.run_sim(
            "tb_sync_role_switch",
            [
                ROOT / "hardware/vivado/src/sync_role_control.v",
                ROOT / "tests/tb_sync_role_switch.sv",
            ],
            "PASS: runtime roles generate and receive a single-pulse sync sequence",
        )

    def test_sync_trigger_link_cdc_and_post_sync_trigger(self):
        self.run_sim(
            "tb_sync_trigger_link",
            [
                ROOT / "hardware/vivado/src/sync_role_control.v",
                ROOT / "hardware/vivado/src/sync_trigger_link.v",
                ROOT / "tests/tb_sync_trigger_link.sv",
            ],
            "PASS: single-pulse XS20 SYNC and independent XS18->XS19 trigger link",
        )

    def test_sync_trigger_link_self_test_bypasses_missing_sync(self):
        self.run_sim(
            "tb_sync_self_test",
            [
                ROOT / "hardware/vivado/src/sync_role_control.v",
                ROOT / "hardware/vivado/src/sync_trigger_link.v",
                ROOT / "tests/tb_sync_self_test.sv",
            ],
            "PASS: self_test bypass accepts XS19 trigger without XS20 SYNC",
        )

    def test_axilite_arbiter_locks_complete_transactions(self):
        self.run_sim(
            "tb_axilite_arbiter_2to1",
            [
                ROOT / "hardware/vivado/src/axilite_arbiter_2to1.v",
                ROOT / "tests/tb_axilite_arbiter_2to1.sv",
            ],
            "PASS: AXI-Lite arbiter locks each write and read transaction to one master",
        )

    def test_interleaved_executor_retains_33bit_total_length(self):
        self.run_sim(
            "tb_waveform_interleaved_rearm",
            [
                ROOT / "tests/axis_data_fifo_1_sim.sv",
                ROOT / "hardware/vivado/src/waveform_interleaved_system_top.v",
                ROOT / "tests/tb_waveform_interleaved_rearm.sv",
            ],
            "PASS: interleaved executor accepts rearm and clears loop state on abort",
        )


if __name__ == "__main__":
    unittest.main()
