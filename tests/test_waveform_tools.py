import sys
import unittest
from importlib import util
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SOFTWARE_DIR = ROOT / "software"
sys.path.insert(0, str(SOFTWARE_DIR))


def load_software_module(module_name: str, filename: str):
    spec = util.spec_from_file_location(module_name, SOFTWARE_DIR / filename)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {filename}")
    module = util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


host = load_software_module("host", "host.py")
waveform_tools = load_software_module("waveform_tools", "waveform_tools.py")


class WaveformToolTests(unittest.TestCase):
    def test_sine_frequency_changes_generated_samples(self):
        low = waveform_tools.make_sine(
            freq_hz=20e6,
            phase_rad=0.0,
            amplitude=20000,
            sample_rate_hz=host.DAC_XY_FS,
            sample_count=host.NUM_SAMPLES,
            encoding="signed",
        )
        high = waveform_tools.make_sine(
            freq_hz=80e6,
            phase_rad=0.0,
            amplitude=20000,
            sample_rate_hz=host.DAC_XY_FS,
            sample_count=host.NUM_SAMPLES,
            encoding="signed",
        )

        self.assertEqual(low.dtype, np.int16)
        self.assertEqual(high.dtype, np.int16)
        self.assertEqual(len(low), host.NUM_SAMPLES)
        self.assertEqual(len(high), host.NUM_SAMPLES)
        self.assertFalse(np.array_equal(low, high))

    def test_sine_sample_rate_changes_generated_samples(self):
        default_rate = waveform_tools.make_sine(
            freq_hz=20e6,
            phase_rad=0.0,
            amplitude=20000,
            sample_rate_hz=host.DAC_XY_FS,
            sample_count=host.NUM_SAMPLES,
            encoding="signed",
        )
        half_rate = waveform_tools.make_sine(
            freq_hz=20e6,
            phase_rad=0.0,
            amplitude=20000,
            sample_rate_hz=host.DAC_XY_FS / 2.0,
            sample_count=host.NUM_SAMPLES,
            encoding="signed",
        )

        self.assertFalse(np.array_equal(default_rate, half_rate))

    def test_gaussian_burst_produces_nonzero_samples(self):
        burst = waveform_tools.make_gaussian_burst(
            freq_hz=80e6,
            phase_rad=0.0,
            amplitude=24000,
            sample_rate_hz=host.DAC_XY_FS,
            duration_s=120e-9,
            delay_s=80e-9,
            sample_count=host.NUM_SAMPLES,
        )

        self.assertEqual(burst.dtype, np.int16)
        self.assertEqual(len(burst), host.NUM_SAMPLES)
        self.assertGreater(np.max(np.abs(burst)), 1000)

    def test_gaussian_burst_delay_is_hardware_only_not_waveform_padding(self):
        no_delay = waveform_tools.make_gaussian_burst(
            freq_hz=80e6,
            phase_rad=0.0,
            amplitude=24000,
            sample_rate_hz=host.DAC_XY_FS,
            duration_s=120e-9,
            delay_s=0.0,
            sample_count=host.NUM_SAMPLES,
        )
        delayed = waveform_tools.make_gaussian_burst(
            freq_hz=80e6,
            phase_rad=0.0,
            amplitude=24000,
            sample_rate_hz=host.DAC_XY_FS,
            duration_s=120e-9,
            delay_s=200e-9,
            sample_count=host.NUM_SAMPLES,
        )

        np.testing.assert_array_equal(no_delay, delayed)

    def test_delay_ns_to_axis_cycles_uses_axis_frequency(self):
        self.assertEqual(waveform_tools.delay_ns_to_axis_cycles(80.0, 300_000_000.0), 24)
        self.assertEqual(waveform_tools.delay_ns_to_axis_cycles(120.0, 300_000_000.0), 36)
        self.assertEqual(waveform_tools.delay_ns_to_axis_cycles(2.0, 250_000_000.0), 0)

    def test_golden_helpers_match_expected_hex(self):
        samples = waveform_tools.make_incrementing_pattern(sample_count=16, start=0)

        self.assertEqual(waveform_tools.expected_axi_wdata_hex(samples), "0x000f000e000d000c000b000a0009000800070006000500040003000200010000")
        self.assertEqual(waveform_tools.lane_bytes_hex(samples), "00 00 01 00 02 00 03 00 04 00 05 00 06 00 07 00 08 00 09 00 0a 00 0b 00 0c 00 0d 00 0e 00 0f 00")
        self.assertEqual(
            waveform_tools.rtl_instruction_tdata_hex(waveform_tools.play_instruction_words(1, host.FIXED_DATA_BYTES, host.DDR_X_ADDR)),
            "0x00000000000000000000100000000012",
        )

    def test_build_play_commands_encodes_loop_and_trigger_modes(self):
        loop_cmds = waveform_tools.build_play_commands(loop=True, auto_start=True)
        trigger_cmds = waveform_tools.build_play_commands(loop=False, auto_start=False)

        self.assertEqual(loop_cmds[-1], [3, 15, 0, 0, 1])
        self.assertEqual(trigger_cmds[-1], [3, 0, 0, 0, 0])
        self.assertEqual(
            [cmd for cmd in loop_cmds if cmd[0] == 2],
            [[2, channel, host.FIXED_DATA_BYTES, host.DDR_CH_ADDR[channel - 1]] for channel in range(1, 9)],
        )


    def test_default_channel_addresses_cover_eight_ddr_slots(self):
        self.assertEqual(waveform_tools.DEFAULT_CHANNEL_ADDRS, {
            1: host.DDR_CH1_ADDR,
            2: host.DDR_CH2_ADDR,
            3: host.DDR_CH3_ADDR,
            4: host.DDR_CH4_ADDR,
            5: host.DDR_CH5_ADDR,
            6: host.DDR_CH6_ADDR,
            7: host.DDR_CH7_ADDR,
            8: host.DDR_CH8_ADDR,
        })

    def test_build_play_commands_emits_play_for_channels_1_through_8(self):
        cmds = waveform_tools.build_play_commands(loop=True, auto_start=True)

        self.assertEqual(cmds, [
            [1, 1, 0, 0],
            [2, 1, host.FIXED_DATA_BYTES, host.DDR_CH1_ADDR],
            [1, 2, 0, 0],
            [2, 2, host.FIXED_DATA_BYTES, host.DDR_CH2_ADDR],
            [1, 3, 0, 0],
            [2, 3, host.FIXED_DATA_BYTES, host.DDR_CH3_ADDR],
            [1, 4, 0, 0],
            [2, 4, host.FIXED_DATA_BYTES, host.DDR_CH4_ADDR],
            [1, 5, 0, 0],
            [2, 5, host.FIXED_DATA_BYTES, host.DDR_CH5_ADDR],
            [1, 6, 0, 0],
            [2, 6, host.FIXED_DATA_BYTES, host.DDR_CH6_ADDR],
            [1, 7, 0, 0],
            [2, 7, host.FIXED_DATA_BYTES, host.DDR_CH7_ADDR],
            [1, 8, 0, 0],
            [2, 8, host.FIXED_DATA_BYTES, host.DDR_CH8_ADDR],
            [3, 15, 0, 0, 1],
        ])

    def test_build_play_commands_encodes_per_channel_idle_delays(self):
        cmds = waveform_tools.build_play_commands(
            loop=False,
            auto_start=True,
            channel_delays={1: 0, 2: 24, 3: 30, 4: 0},
        )

        self.assertEqual(cmds[0], [1, 1, 0, 0])
        self.assertEqual(cmds[2], [1, 2, 24, 0])
        self.assertEqual(cmds[4], [1, 3, 30, 0])
        self.assertEqual(cmds[6], [1, 4, 0, 0])

    def test_upload_and_play_uploads_supplied_four_channel_arrays(self):
        arrays = [np.full(8, value, dtype=np.int16) for value in (1, 2, 3, 4)]
        calls = []

        class FakeController:
            def __init__(self, *args, **kwargs):
                calls.append(("init", args, kwargs))

            def upload_waveform_udp(self, samples, ddr_addr, dump_path):
                calls.append(("upload", int(samples[0]), ddr_addr, Path(dump_path).name))

            def send_instructions(self, commands):
                calls.append(("instructions", commands))

            def close(self):
                calls.append(("close",))

        original = waveform_tools.host.RFSocController
        waveform_tools.host.RFSocController = FakeController
        try:
            waveform_tools.upload_and_play(
                arrays[0],
                arrays[1],
                ch3=arrays[2],
                ch4=arrays[3],
                ip="192.0.2.10",
                port=1234,
                udp_interface="eth0",
                udp_source_ip="192.0.2.1",
                timeout_s=1.0,
                post_upload_sleep_s=0.0,
                output_dir=Path("/tmp/four-channel-test"),
                loop=False,
                auto_start=True,
            )
        finally:
            waveform_tools.host.RFSocController = original

        upload_calls = [call for call in calls if call[0] == "upload"]
        self.assertEqual(upload_calls, [
            ("upload", 1, host.DDR_CH1_ADDR, "ch1_upload_hex.txt"),
            ("upload", 2, host.DDR_CH2_ADDR, "ch2_upload_hex.txt"),
            ("upload", 3, host.DDR_CH3_ADDR, "ch3_upload_hex.txt"),
            ("upload", 4, host.DDR_CH4_ADDR, "ch4_upload_hex.txt"),
        ])
        instruction_calls = [call for call in calls if call[0] == "instructions"]
        self.assertEqual(instruction_calls[0][1][1], [2, 1, host.FIXED_DATA_BYTES, host.DDR_CH1_ADDR])
        self.assertEqual(instruction_calls[0][1][3], [2, 2, host.FIXED_DATA_BYTES, host.DDR_CH2_ADDR])
        self.assertEqual(instruction_calls[0][1][5], [2, 3, host.FIXED_DATA_BYTES, host.DDR_CH3_ADDR])
        self.assertEqual(instruction_calls[0][1][7], [2, 4, host.FIXED_DATA_BYTES, host.DDR_CH4_ADDR])

    def test_waveform_metadata_uses_explicit_units(self):
        metadata = waveform_tools.build_metadata(
            mode="sine",
            sample_rate_hz=host.DAC_XY_FS,
            x_freq_hz=20e6,
            y_freq_hz=40e6,
            encoding="signed",
            loop=True,
        )

        self.assertEqual(metadata["sample_rate_hz"], host.DAC_XY_FS)
        self.assertEqual(metadata["samples_per_channel"], host.NUM_SAMPLES)
        self.assertEqual(metadata["bytes_per_channel"], host.FIXED_DATA_BYTES)
        self.assertEqual(metadata["x_freq_hz"], 20e6)
        self.assertEqual(metadata["y_freq_hz"], 40e6)
        self.assertTrue(metadata["loop"])
        self.assertEqual(metadata["ch1_ddr_offset"], f"0x{host.DDR_CH1_ADDR:016X}")
        self.assertEqual(metadata["ch2_ddr_offset"], f"0x{host.DDR_CH2_ADDR:016X}")
        self.assertEqual(metadata["ch3_ddr_offset"], f"0x{host.DDR_CH3_ADDR:016X}")
        self.assertEqual(metadata["ch4_ddr_offset"], f"0x{host.DDR_CH4_ADDR:016X}")
        self.assertEqual(metadata["ch5_ddr_offset"], f"0x{host.DDR_CH5_ADDR:016X}")
        self.assertEqual(metadata["ch6_ddr_offset"], f"0x{host.DDR_CH6_ADDR:016X}")
        self.assertEqual(metadata["ch7_ddr_offset"], f"0x{host.DDR_CH7_ADDR:016X}")
        self.assertEqual(metadata["ch8_ddr_offset"], f"0x{host.DDR_CH8_ADDR:016X}")
        self.assertEqual(metadata["ch1_dac_port"], "s00_axis")
        self.assertEqual(metadata["ch2_dac_port"], "s02_axis")
        self.assertEqual(metadata["ch3_dac_port"], "s10_axis")
        self.assertEqual(metadata["ch4_dac_port"], "s12_axis")
        self.assertEqual(metadata["ch5_dac_port"], "s20_axis")
        self.assertEqual(metadata["ch6_dac_port"], "s22_axis")
        self.assertEqual(metadata["ch7_dac_port"], "s30_axis")
        self.assertEqual(metadata["ch8_dac_port"], "s32_axis")
        self.assertEqual(metadata["ch1_dac_outputs"], ["vout00"])
        self.assertEqual(metadata["ch2_dac_outputs"], ["vout02"])
        self.assertEqual(metadata["ch3_dac_outputs"], ["vout10"])
        self.assertEqual(metadata["ch4_dac_outputs"], ["vout12"])
        self.assertEqual(metadata["ch5_dac_outputs"], ["vout20"])
        self.assertEqual(metadata["ch6_dac_outputs"], ["vout22"])
        self.assertEqual(metadata["ch7_dac_outputs"], ["vout30"])
        self.assertEqual(metadata["ch8_dac_outputs"], ["vout32"])
        self.assertEqual(metadata["x_ddr_offset"], metadata["ch1_ddr_offset"])
        self.assertEqual(metadata["y_ddr_offset"], metadata["ch2_ddr_offset"])

    def test_pack_iq_tile_buffer_uses_interleaved_iq_lanes(self):
        i_wave = np.arange(100, 116, dtype=np.int16)
        q_wave = np.arange(200, 216, dtype=np.int16)

        packed = waveform_tools.pack_iq_tile_buffer(i_wave, q_wave, sample_count=32)

        self.assertEqual(packed.dtype, np.int16)
        self.assertEqual(len(packed), 32)
        np.testing.assert_array_equal(packed[0::2], i_wave)
        np.testing.assert_array_equal(packed[1::2], q_wave)
        np.testing.assert_array_equal(
            packed[:16],
            np.array([100, 200, 101, 201, 102, 202, 103, 203, 104, 204, 105, 205, 106, 206, 107, 207], dtype=np.int16),
        )

    def test_iq_sine_tile_waveform_uses_varying_interleaved_iq_lanes(self):
        wave = waveform_tools.make_iq_sine_tile_waveform(
            freq_hz=80e6,
            phase_rad=0.0,
            amplitude=16000,
            sample_rate_hz=host.DAC_XY_FS,
        )

        self.assertEqual(wave.dtype, np.int16)
        self.assertEqual(len(wave), host.NUM_SAMPLES)
        self.assertGreater(len(set(wave[0:64:2].tolist())), 4)
        self.assertGreater(len(set(wave[1:64:2].tolist())), 4)
        self.assertEqual(wave[0], 16000)
        self.assertEqual(wave[1], 0)

    def test_pypulse_tile_waveforms_generate_iq_and_z_zero_q(self):
        xy, xy_metadata = waveform_tools.make_pypulse_tile_waveform(
            "xy",
            freq_hz=80e6,
            phase_rad=0.0,
            amplitude=20000,
            sample_rate_hz=host.DAC_XY_FS,
            duration_s=120e-9,
        )
        z, z_metadata = waveform_tools.make_pypulse_tile_waveform(
            "z",
            freq_hz=80e6,
            phase_rad=0.0,
            amplitude=20000,
            sample_rate_hz=host.DAC_XY_FS,
            duration_s=120e-9,
        )

        self.assertEqual(len(xy), host.NUM_SAMPLES)
        self.assertEqual(xy_metadata["waveform"], "xy")
        self.assertEqual(xy_metadata["i_signal"], "xy_i")
        self.assertEqual(xy_metadata["q_signal"], "xy_q")
        self.assertGreater(int(np.max(np.abs(xy[0::2]))), 1000)
        self.assertEqual(z_metadata["waveform"], "z")
        self.assertEqual(z_metadata["q_signal"], "zero_q")
        self.assertFalse(np.any(z[1::2]))

    def test_pypulse_waveform_bundle_preserves_upload_contract(self):
        *waves, metadata = waveform_tools.make_pypulse_waveform_bundle(
            sample_rate_hz=host.DAC_XY_FS,
            loop=True,
            amplitude=21000,
            duration_s=120e-9,
            xy_freq_hz=90e6,
            readout_freq_hz=140e6,
        )

        self.assertEqual(len(waves), 8)
        for wave in waves:
            self.assertEqual(wave.dtype, np.int16)
            self.assertEqual(len(wave), host.NUM_SAMPLES)
        self.assertEqual(metadata["mode"], "pypulse")
        self.assertEqual(metadata["encoding"], "signed-iq-interleaved")
        self.assertTrue(metadata["loop"])
        self.assertEqual(metadata["ch1_pypulse_waveform"], "xy")
        self.assertEqual(metadata["ch2_pypulse_waveform"], "z")
        self.assertEqual(metadata["ch3_pypulse_waveform"], "readout")
        self.assertEqual(metadata["ch4_pypulse_waveform"], "readout")
        self.assertEqual(metadata["ch5_pypulse_waveform"], "xy")
        self.assertEqual(metadata["ch6_pypulse_waveform"], "z")
        self.assertEqual(metadata["ch7_pypulse_waveform"], "readout")
        self.assertEqual(metadata["ch8_pypulse_waveform"], "readout")
        self.assertEqual(metadata["ch2_q_signal"], "zero_q")
        self.assertEqual(metadata["ch6_q_signal"], "zero_q")
        self.assertEqual(metadata["xy_freq_hz"], 90e6)
        self.assertEqual(metadata["readout_freq_hz"], 140e6)


if __name__ == "__main__":
    unittest.main()
