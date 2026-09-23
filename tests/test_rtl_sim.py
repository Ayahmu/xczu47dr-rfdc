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
    def test_waveform_fifo_mask_adapter(self):
        self.run_sim(
            "tb_waveform_fifo_mask_adapter",
            [ROOT / "hardware/vivado/src/waveform_fifo_mask_adapter.v",
             ROOT / "tests/tb_waveform_fifo_mask_adapter.sv"],
            "PASS: disabled FIFO lanes cannot block or consume reader credit",
        )

    def test_waveform_dac_stream(self):
        self.run_sim("tb_waveform_dac_stream",
                     [ROOT / "hardware/vivado/src/waveform_dac_stream.v",
                      ROOT / "tests/tb_waveform_dac_stream.sv"],
                     "PASS: eight-channel DAC fires, backpressure, tail and zero silence")

    def test_waveform_ddr_reader(self):
        self.run_sim("tb_waveform_ddr_reader",
                     [ROOT / "hardware/vivado/src/waveform_ddr_reader.v",
                      ROOT / "tests/tb_waveform_ddr_reader.sv"],
                     "PASS: waveform reader credits, interleave, cancel, AXI errors and timeout")

    def test_waveform_response_serializer(self):
        self.run_sim("tb_waveform_response_serializer",
                     [ROOT / "hardware/vivado/src/waveform_response_serializer.v",
                      ROOT / "tests/tb_waveform_response_serializer.sv"],
                     "PASS: waveform response golden bytes and AXIS backpressure")

    def test_waveform_simultaneous_event_priority(self):
        self.run_sim(
            "tb_waveform_event_priority",
            [ROOT / "hardware/vivado/src/waveform_playback_controller.v",
             ROOT / "tests/tb_waveform_event_priority.sv"],
            "PASS: waveform simultaneous events preserve fault and stop priority",
        )

    def test_unified_waveform_trigger_cdc(self):
        self.run_sim(
            "tb_waveform_trigger_cdc",
            [
                ROOT / "hardware/vivado/src/waveform_trigger_cdc.v",
                ROOT / "tests/tb_waveform_trigger_cdc.sv",
            ],
            "PASS: narrow trigger CDC captures one event and never queues it",
        )

    def test_unified_waveform_status_cdc(self):
        self.run_sim(
            "tb_waveform_status_cdc",
            [ROOT / "hardware/vivado/src/waveform_status_cdc.v",
             ROOT / "tests/tb_waveform_status_cdc.sv"],
            "PASS: waveform status snapshot CDC holds a coherent source record",
        )

    def test_unified_waveform_status_serializer(self):
        self.run_sim(
            "tb_waveform_status_serializer",
            [ROOT / "hardware/vivado/src/waveform_response_serializer.v",
             ROOT / "tests/tb_waveform_status_serializer.sv"],
            "PASS: waveform STATUS snapshot serializer returns beat, loop, FIFO, error and trigger fields",
        )

    def test_unified_waveform_upload_writer(self):
        self.run_sim(
            "tb_waveform_upload_writer",
            [
                ROOT / "hardware/vivado/src/waveform_upload_writer.v",
                ROOT / "tests/tb_waveform_upload_writer.sv",
            ],
            "PASS: WAVECTR0 writer validates CRC, emits aligned writes, and advances ACK only after AXI B responses",
        )

    def test_unified_waveform_playback_controller(self):
        self.run_sim(
            "tb_waveform_playback_controller",
            [
                ROOT / "hardware/vivado/src/waveform_playback_controller.v",
                ROOT / "tests/tb_waveform_playback_controller.sv",
            ],
            "PASS: unified waveform playback state machine gates and counts events",
        )

    def test_udp_rvctrl_framer(self):
        self.run_sim(
            "tb_udp_rvctrl_framer",
            [
                ROOT / "hardware/vivado/src/udp_rvctrl_framer.v",
                ROOT / "tests/tb_udp_rvctrl_framer.sv",
            ],
            "PASS: udp_rvctrl_framer framing contract",
        )

    def test_unified_waveform_playback_path(self):
        self.run_sim(
            "tb_waveform_playback_path",
            [
                ROOT / "hardware/vivado/src/waveform_command_cdc.v",
                ROOT / "hardware/vivado/src/waveform_descriptor_cdc.v",
                ROOT / "hardware/vivado/src/waveform_pulse_sync.v",
                ROOT / "hardware/vivado/src/waveform_trigger_cdc.v",
                ROOT / "hardware/vivado/src/waveform_playback_controller.v",
                ROOT / "hardware/vivado/src/waveform_ddr_reader.v",
                ROOT / "hardware/vivado/src/waveform_dac_stream.v",
                ROOT / "hardware/vivado/src/waveform_playback_path.v",
                ROOT / "tests/tb_waveform_playback_path.sv",
            ],
            "PASS: descriptor path prefetches, admits trigger once, and drains playback",
        )

    def test_unified_waveform_prefetch_fits_full_load(self):
        self.run_sim(
            "tb_waveform_prefetch_fits_full_load",
            [
                ROOT / "hardware/vivado/src/waveform_command_cdc.v",
                ROOT / "hardware/vivado/src/waveform_descriptor_cdc.v",
                ROOT / "hardware/vivado/src/waveform_pulse_sync.v",
                ROOT / "hardware/vivado/src/waveform_trigger_cdc.v",
                ROOT / "hardware/vivado/src/waveform_playback_controller.v",
                ROOT / "hardware/vivado/src/waveform_ddr_reader.v",
                ROOT / "hardware/vivado/src/waveform_dac_stream.v",
                ROOT / "hardware/vivado/src/waveform_playback_path.v",
                ROOT / "tests/tb_waveform_prefetch_fits_full_load.sv",
            ],
            "PASS: fits-in-FIFO fully prefetches; oversized keeps the streaming watermark",
        )

    def test_unified_waveform_stream_throughput(self):
        self.run_sim(
            "tb_waveform_stream_throughput",
            [
                ROOT / "hardware/vivado/src/waveform_command_cdc.v",
                ROOT / "hardware/vivado/src/waveform_descriptor_cdc.v",
                ROOT / "hardware/vivado/src/waveform_pulse_sync.v",
                ROOT / "hardware/vivado/src/waveform_trigger_cdc.v",
                ROOT / "hardware/vivado/src/waveform_playback_controller.v",
                ROOT / "hardware/vivado/src/waveform_ddr_reader.v",
                ROOT / "hardware/vivado/src/waveform_dac_stream.v",
                ROOT / "hardware/vivado/src/waveform_playback_path.v",
                ROOT / "tests/tb_waveform_stream_throughput.sv",
            ],
            "PASS: streaming descriptor larger than the FIFO drains with no underflow",
        )

    def run_sim(self, top: str, sources: list[Path], expected: str) -> None:
        with tempfile.TemporaryDirectory(prefix=f"{top}-") as temp_dir:
            workdir = Path(temp_dir)

            def run(command: list[str], timeout: int):
                try:
                    result = subprocess.run(command, cwd=workdir, check=True,
                                            text=True, capture_output=True, timeout=timeout)
                except subprocess.CalledProcessError as exc:
                    self.fail(f"{command[0]} failed for {top}:\n{exc.stdout}\n{exc.stderr}")
                except subprocess.TimeoutExpired as exc:
                    self.fail(f"{command[0]} timed out for {top}:\n{exc.stdout}\n{exc.stderr}")
                return result

            # Benches that instantiate the full playback path link the real
            # xpm_fifo_async simulation model, which references the standard
            # Vivado global primitive.  TDC benches intentionally provide a
            # local adversarial stub and must not link XPM.
            xpm_tops = {"tb_waveform_playback_path", "tb_waveform_prefetch_fits_full_load",
                        "tb_waveform_stream_throughput"}
            compile_sources = [str(source) for source in sources]
            if top in xpm_tops:
                compile_sources.append("/tools/Xilinx/Vivado/2024.2/data/verilog/src/glbl.v")
            run([vivado_tool("xvlog"), "-sv", *compile_sources], 120)
            # The integrated playback path uses Xilinx's asynchronous FIFO
            # primitive for the ordered command/descriptor CDC.  Keep the
            # simulator invocation explicit so this test exercises the same
            # primitive library as Vivado elaboration instead of silently
            # replacing the CDC with a test-only model.
            elab_top = [top]
            if top in xpm_tops:
                elab_top.append("glbl")
            elab_command = [vivado_tool("xelab"), *elab_top]
            if top in xpm_tops:
                elab_command.extend(["-L", "xpm"])
            run([*elab_command, "-s", "sim"], 120)
            result = run([vivado_tool("xsim"), "sim", "-runall"], 180)
            self.assertNotIn("Fatal:", result.stdout)
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

    def test_udp_writer_full_fifo_read_write_collision(self):
        self.run_sim(
            "tb_udp_writer_fifo_collision",
            [ROOT / "hardware/vivado/src/udp_waveform_ddr_writer.v",
             ROOT / "tests/tb_udp_writer_fifo_collision.sv"],
            "PASS: writer FIFO preserves old data on full push/pop and resets admission",
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

    def test_waveform_status_crosses_writer_and_control_response_path(self):
        self.run_sim(
            "tb_rfctrl2_control_path",
            [
                ROOT / "hardware/vivado/src/udp_waveform_ddr_writer.v",
                ROOT / "hardware/vivado/src/pl_riscv_control_v1.v",
                ROOT / "tests/tb_rfctrl2_control_path.sv",
            ],
            "PASS: waveform STATUS payload crosses the UDP writer and PL control response path",
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

    def test_arp_cache_ignores_off_subnet_broadcast_senders(self):
        self.run_sim(
            "tb_arp_local_subnet_filter",
            [
                ROOT / "hardware/vivado/src/udp/lfsr.v",
                ROOT / "hardware/vivado/src/udp/arp_cache.v",
                ROOT / "hardware/vivado/src/udp/arp_eth_rx.v",
                ROOT / "hardware/vivado/src/udp/arp_eth_tx.v",
                ROOT / "hardware/vivado/src/udp/arp.v",
                ROOT / "tests/tb_arp_local_subnet_filter.sv",
            ],
            "PASS: ARP cache learns only local-subnet senders",
        )

    def test_pl_riscv_control_v1_rejects_removed_rfctrl2_playback(self):
        self.run_sim(
            "tb_pl_riscv_control_v1",
            [
                ROOT / "hardware/vivado/src/pl_riscv_control_v1.v",
                ROOT / "tests/tb_pl_riscv_control_v1.sv",
            ],
            "PASS: PL control shim rejects removed RFCTRL2 playback commands and preserves RFDC_APPLY/SYNC_EPOCH",
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

    def test_dac_direct_external_trigger_capture_and_latency_probe(self):
        self.run_sim(
            "tb_dac_direct_trigger",
            [
                ROOT / "hardware/vivado/src/dac_ext_trigger_capture.v",
                ROOT / "hardware/vivado/src/dac_trigger_latency_probe.v",
                ROOT / "tests/tb_dac_direct_trigger.sv",
            ],
            "PASS: DAC direct trigger capture and latency probe behave as specified",
        )

    def test_dac_domain_trigger_emitter(self):
        self.run_sim(
            "tb_dac_trigger_emitter",
            [
                ROOT / "hardware/vivado/src/dac_trigger_emitter.v",
                ROOT / "tests/tb_dac_trigger_emitter.sv",
            ],
            "PASS: dac_trigger_emitter emits one gated DAC-domain pulse per request",
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


if __name__ == "__main__":
    unittest.main()
