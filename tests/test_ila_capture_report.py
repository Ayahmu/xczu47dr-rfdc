import argparse
import json
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SOFTWARE_DIR = ROOT / "software"
sys.path.insert(0, str(SOFTWARE_DIR))

import ila_capture_report  # type: ignore[import-not-found]  # noqa: E402


class IlaCaptureReportTests(unittest.TestCase):
    def test_software_data_mode_decodes_one_256_bit_word_per_valid_cycle(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            artifact_dir = root / "artifacts"
            artifact_dir.mkdir()
            metadata = {"bytes_per_channel": 32}
            (artifact_dir / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
            waves = {
                channel: np.arange((channel - 1) * 100, (channel - 1) * 100 + 16, dtype=np.int16)
                for channel in range(1, 9)
            }
            for channel, wave in waves.items():
                np.save(artifact_dir / f"ch{channel}_waveform.npy", wave)

            def word_hex(wave: np.ndarray) -> str:
                word = int.from_bytes(wave.astype("<i2").tobytes(), byteorder="little", signed=False)
                return f"0x{word:064x}"

            csv_path = root / "software_data.csv"
            header = ["Sample"]
            row0 = ["0"]
            row1 = ["1"]
            for channel in range(1, 9):
                valid = f"top_i/dac_ch{channel}_valid_gated"
                data = f"top_i/dac_in_ch{channel}_tdata"
                header.extend([valid, data])
                row0.extend(["0", "0x0"])
                row1.extend(["1", word_hex(waves[channel])])
            csv_path.write_text(",".join(header) + "\n" + ",".join(row0) + "\n" + ",".join(row1) + "\n", encoding="utf-8")
            args = argparse.Namespace(
                artifact_dir=artifact_dir,
                expected_delay_cycles="",
                probe_map=None,
                trigger_probe="top_i/dac_ch1_valid_gated",
            )

            details, _ = ila_capture_report.analyze(args, csv_path)

        self.assertEqual(details["overall_status"], "PASS")
        for channel in details["channels"]:
            self.assertEqual(channel["expected_valid_cycles"], 1)
            self.assertEqual(channel["captured_samples"], 16)
            self.assertEqual(channel["matched_samples"], 16)

    def test_loop_mode_validates_each_window_against_same_waveform(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            artifact_dir = root / "artifacts"
            artifact_dir.mkdir()
            metadata = {"bytes_per_channel": 32, "loop": True}
            (artifact_dir / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
            waves = {
                channel: np.arange((channel - 1) * 100, (channel - 1) * 100 + 16, dtype=np.int16)
                for channel in range(1, 9)
            }
            for channel, wave in waves.items():
                np.save(artifact_dir / f"ch{channel}_waveform.npy", wave)

            def word_hex(wave: np.ndarray) -> str:
                word = int.from_bytes(wave.astype("<i2").tobytes(), byteorder="little", signed=False)
                return f"0x{word:064x}"

            header = ["Sample"]
            rows = [["0"], ["1"], ["2"], ["3"]]
            for channel in range(1, 9):
                valid = f"top_i/dac_ch{channel}_valid_gated"
                data = f"top_i/dac_in_ch{channel}_tdata"
                header.extend([valid, data])
                wave_word = word_hex(waves[channel])
                rows[0].extend(["0", "0x0"])
                rows[1].extend(["1", wave_word])
                rows[2].extend(["0", "0x0"])
                rows[3].extend(["1", wave_word])
            csv_path = root / "loop.csv"
            csv_path.write_text(
                ",".join(header) + "\n" + "\n".join(",".join(row) for row in rows) + "\n",
                encoding="utf-8",
            )
            args = argparse.Namespace(
                artifact_dir=artifact_dir,
                expected_delay_cycles="",
                probe_map=None,
                trigger_probe="top_i/dac_ch1_valid_gated",
            )

            details, markdown = ila_capture_report.analyze(args, csv_path)

        self.assertEqual(details["overall_status"], "PASS")
        self.assertIn("loop mode", markdown)
        for channel in details["channels"]:
            self.assertEqual(channel["expected_valid_cycles"], 2)
            self.assertEqual(channel["valid_cycles"], 2)
            self.assertEqual(channel["captured_samples"], 32)
            self.assertEqual(channel["expected_samples"], 32)
            self.assertEqual(channel["matched_samples"], 32)

    def test_loop_mode_accepts_capture_starting_mid_waveform(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            artifact_dir = root / "artifacts"
            artifact_dir.mkdir()
            metadata = {"bytes_per_channel": 64, "loop": True}
            (artifact_dir / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
            waves = {
                channel: np.arange((channel - 1) * 100, (channel - 1) * 100 + 32, dtype=np.int16)
                for channel in range(1, 9)
            }
            for channel, wave in waves.items():
                np.save(artifact_dir / f"ch{channel}_waveform.npy", wave)

            def word_hex(wave: np.ndarray) -> str:
                word = int.from_bytes(wave.astype("<i2").tobytes(), byteorder="little", signed=False)
                return f"0x{word:064x}"

            header = ["Sample"]
            rows = [["0"], ["1"], ["2"]]
            for channel in range(1, 9):
                valid = f"top_i/dac_ch{channel}_valid_gated"
                data = f"top_i/dac_in_ch{channel}_tdata"
                header.extend([valid, data])
                rows[0].extend(["1", word_hex(waves[channel][16:32])])
                rows[1].extend(["0", "0x0"])
                rows[2].extend(["1", word_hex(waves[channel][0:16])])
            csv_path = root / "loop_mid_waveform.csv"
            csv_path.write_text(
                ",".join(header) + "\n" + "\n".join(",".join(row) for row in rows) + "\n",
                encoding="utf-8",
            )
            args = argparse.Namespace(
                artifact_dir=artifact_dir,
                expected_delay_cycles="",
                probe_map=None,
                trigger_probe="top_i/dac_ch1_valid_gated",
            )

            details, _ = ila_capture_report.analyze(args, csv_path)

        self.assertEqual(details["overall_status"], "PASS")
        for channel in details["channels"]:
            self.assertEqual(channel["valid_cycles"], 2)
            self.assertEqual(channel["expected_valid_cycles"], 2)
            self.assertEqual(channel["captured_samples"], 32)
            self.assertEqual(channel["expected_samples"], 32)
            self.assertEqual(channel["matched_samples"], 32)

    def test_hardware_cw_mode_passes_with_continuous_allow_valid(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            artifact_dir = root / "artifacts"
            artifact_dir.mkdir()
            (artifact_dir / "metadata.json").write_text(json.dumps({"hardware_cw_mode": True}), encoding="utf-8")
            csv_path = root / "cw.csv"
            csv_path.write_text(
                ",".join(["Sample", *[f"top_i/ch{channel}_allow" for channel in range(1, 9)], "top_i/pc_trig_start"])
                + "\n"
                + "0,1,1,1,1,1,1,1,1,1\n"
                + "1,1,1,1,1,1,1,1,1,0\n"
                + "2,1,1,1,1,1,1,1,1,0\n",
                encoding="utf-8",
            )
            probe_map = root / "probe_map.json"
            probe_map.write_text(
                json.dumps(
                    {f"ch{channel}_valid": f"top_i/ch{channel}_allow" for channel in range(1, 9)}
                ),
                encoding="utf-8",
            )
            args = argparse.Namespace(
                artifact_dir=artifact_dir,
                expected_delay_cycles="",
                probe_map=probe_map,
                trigger_probe="top_i/pc_trig_start",
            )

            details, markdown = ila_capture_report.analyze(args, csv_path)

        self.assertEqual(details["overall_status"], "PASS")
        self.assertTrue(details["hardware_cw_mode"])
        self.assertIn("hardware CW mode", markdown)
        self.assertTrue(all(channel["status"] == "PASS" for channel in details["channels"]))


if __name__ == "__main__":
    unittest.main()
