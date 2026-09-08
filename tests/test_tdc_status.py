import struct
import unittest

from software.dr47 import Dr47Device
from software.dr47.protocol import RFCTRL2_VERSION
from software.dr47.protocol import parse_rfctrl2_status_payload


class TdcStatusTests(unittest.TestCase):
    def test_status_decodes_complete_tdc_measurement(self):
        tdc_word = (
            2
            | (1 << 3)
            | (1 << 4)
            | (1 << 5)
            | (137 << 8)
            | (1234 << 16)
        )
        payload = bytes(112) + struct.pack("<Q", tdc_word)

        decoded = parse_rfctrl2_status_payload({"payload": payload})

        self.assertEqual(decoded["ext_trigger_phase_slot"], 2)
        self.assertTrue(decoded["ext_trigger_phase_valid"])
        self.assertTrue(decoded["ext_trigger_phase_overflow"])
        self.assertTrue(decoded["ext_trigger_phase_metastable"])
        self.assertEqual(decoded["ext_trigger_tap_index"], 137)
        self.assertEqual(decoded["ext_trigger_phase_ps_x10"], 1234)

    def test_legacy_status_defaults_new_tdc_fields(self):
        decoded = parse_rfctrl2_status_payload({"payload": bytes(96)})

        self.assertFalse(decoded["ext_trigger_phase_valid"])
        self.assertFalse(decoded["ext_trigger_phase_overflow"])
        self.assertFalse(decoded["ext_trigger_phase_metastable"])
        self.assertEqual(decoded["ext_trigger_phase_slot"], 0)
        self.assertEqual(decoded["ext_trigger_tap_index"], 0)
        self.assertEqual(decoded["ext_trigger_phase_ps_x10"], 0)

    def test_device_capabilities_expose_tdc_measurement(self):
        tdc_word = 3 | (1 << 3) | (55 << 8) | (987 << 16)
        payload = bytes(112) + struct.pack("<Q", tdc_word)
        device = Dr47Device()

        capabilities = device._update_from_status(
            {"payload": payload, "version": RFCTRL2_VERSION}
        )

        self.assertEqual(capabilities.ext_trigger_phase_slot, 3)
        self.assertTrue(capabilities.ext_trigger_phase_valid)
        self.assertFalse(capabilities.ext_trigger_phase_overflow)
        self.assertFalse(capabilities.ext_trigger_phase_metastable)
        self.assertEqual(capabilities.ext_trigger_tap_index, 55)
        self.assertEqual(capabilities.ext_trigger_phase_ps_x10, 987)


if __name__ == "__main__":
    unittest.main()
