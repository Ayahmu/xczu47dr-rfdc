import struct
import unittest
from unittest.mock import patch

from software.dr47 import Dr47Device
from software.dr47.errors import ParameterRangeError, ProtocolError
from software.dr47.protocol import pack_rfctrl2_tdc_register, parse_rfctrl2_tdc_register_response
from software.dr47.tdc import TAPS, calibration_from_histogram, validate_table


class TdcCalibrationTests(unittest.TestCase):
    def test_uniform_code_density_yields_monotonic_bin_centers(self):
        result = calibration_from_histogram([1024] * (TAPS//2) + [0] * (TAPS//2))
        self.assertEqual(result["samples"], 1024 * (TAPS//2))
        self.assertLess(result["largest_bin_ps"], 10)
        self.assertEqual(result["table"][0], 0)
        self.assertEqual(result["table"][-1], 500)
        validate_table(result["table"])

    def test_sparse_nonuniform_or_short_calibration_is_rejected(self):
        for counts in ([1000000] + [0] * (TAPS-1), [1] * TAPS, [100000] * 32 + [0] * (TAPS-32)):
            with self.assertRaises(ValueError):
                calibration_from_histogram(counts)

    def test_invalid_calibration_table_is_rejected(self):
        for table in ([0] * TAPS, [0] * (TAPS-1), list(range(TAPS)), [500, 0] + [500] * (TAPS-2)):
            with self.assertRaises(ValueError):
                validate_table(table)

    def test_register_wire_contract_and_validation(self):
        packet = pack_rfctrl2_tdc_register(0x1040, write=True, data=213, seq=37)
        self.assertEqual(struct.unpack("<IIII", packet[24:]), (1, 0x1040, 213, 0))
        self.assertEqual(parse_rfctrl2_tdc_register_response(
            {"payload": struct.pack("<II", 0x1040, 213)}, 0x1040), 213)
        for address in (-4, 2, 65536, 1.5):
            with self.assertRaises(ParameterRangeError):
                pack_rfctrl2_tdc_register(address)
        with self.assertRaises(ProtocolError):
            parse_rfctrl2_tdc_register_response({"payload": bytes(8)}, 4)

    def test_driver_does_not_retry_side_effecting_write(self):
        board = Dr47Device()
        response = {"version": 2, "status": 0, "payload": struct.pack("<II", 4, 1)}
        with patch.object(board, "_require_connected"), patch.object(board, "_request", return_value=response) as request:
            self.assertEqual(board.write_tdc_register(4, 1), 1)
            self.assertEqual(request.call_args.kwargs["retries"], 0)


if __name__ == "__main__":
    unittest.main()
