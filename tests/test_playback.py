import struct
import sys
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "software"))

from dr47 import (  # noqa: E402
    BurstSchedule,
    CMD_REPEAT,
    REPEAT_FLAG_DEBUG_ALTERNATE,
    pack_udp_instruction_packet,
    make_burst_record,
)
from dr47.errors import ParameterRangeError  # noqa: E402


class PlaybackScheduleTests(unittest.TestCase):
    def test_schedule_quantizes_upward_to_axis_clock(self):
        schedule = BurstSchedule(389, 400000, 1200).quantized()
        self.assertEqual(schedule.first_delay_cycles, 20)
        self.assertEqual(schedule.effective_first_delay_ns, 400)
        self.assertEqual(schedule.interval_cycles, 20000)

    def test_burst_record_has_one_pulse_and_period_padding(self):
        active = np.arange(16, dtype=np.int16)
        record, meta = make_burst_record(
            active, first_delay_ns=389, interval_ns=500, sample_rate_hz=400e6
        )
        self.assertEqual(meta["effective_first_delay_ns"], 400)
        self.assertEqual(meta["effective_interval_ns"], 500)
        self.assertEqual(record.size, 400)
        self.assertTrue(np.array_equal(record[320:336], active))
        self.assertTrue(np.all(record[:320] == 0))
        self.assertTrue(np.all(record[336:] == 0))

    def test_burst_record_rejects_overlap(self):
        with self.assertRaises(ParameterRangeError):
            make_burst_record(
                np.ones(32, dtype=np.int16),
                first_delay_ns=100,
                interval_ns=100,
                sample_rate_hz=400e6,
            )

    def test_repeat_instruction_wire_layout(self):
        packet = pack_udp_instruction_packet(
            [[CMD_REPEAT, 0, 7, 0, REPEAT_FLAG_DEBUG_ALTERNATE]]
        )
        word0, value, addr_lo, addr_hi = struct.unpack_from("<IIII", packet, 16)
        self.assertEqual(word0 & 0xF, CMD_REPEAT)
        self.assertEqual((word0 >> 8) & 0x7, REPEAT_FLAG_DEBUG_ALTERNATE)
        self.assertEqual(value, 7)
        self.assertEqual(addr_lo | (addr_hi << 32), 0)


if __name__ == "__main__":
    unittest.main()
