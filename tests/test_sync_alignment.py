import struct
import unittest

from software.dr47 import SimulatedDr47Device, SyncGroup
from software.dr47.errors import SynchronizationError
from software.dr47.protocol import parse_rfctrl2_status_payload


class RuntimeSyncAlignmentTests(unittest.TestCase):
    def test_status_extension_is_backward_compatible(self):
        old = struct.pack("<IIIIIIII", 0, 0, 0, 0, 0, 0, 0, 0)
        decoded = parse_rfctrl2_status_payload({"payload": old})
        self.assertFalse(decoded["sync_align_busy"])
        self.assertEqual(decoded["sync_alignment_epoch"], 0)

        alignment_word = 7 | (1 << 22)
        extended = old + (b"\0" * 64) + struct.pack("<QII", alignment_word, 0x1234, 0)
        decoded = parse_rfctrl2_status_payload({"payload": extended})
        self.assertTrue(decoded["sync_align_busy"])
        self.assertEqual(decoded["sync_alignment_epoch"], 7)
        self.assertEqual(decoded["sync_alignment_error"], 0x1234)

    def test_sync_group_realigns_both_boards_and_requires_repeated_epochs(self):
        master = SimulatedDr47Device(sync_role="master", device_uid="master")
        slave = SimulatedDr47Device(sync_role="slave", device_uid="slave")
        master.connect()
        slave.connect()
        result1 = SyncGroup(master, slave, timeout_s=0.2, poll_interval_s=0.001).sync(epoch=11)
        result2 = SyncGroup(master, slave, timeout_s=0.2, poll_interval_s=0.001).sync(epoch=12)
        self.assertEqual(result1.master_alignment_epoch, 1)
        self.assertEqual(result1.slave_alignment_epoch, 1)
        self.assertEqual(result2.master_alignment_epoch, 2)
        self.assertEqual(result2.slave_alignment_epoch, 2)
        self.assertFalse(master.status().capabilities.sync_align_busy)
        self.assertFalse(slave.status().capabilities.sync_align_busy)

    def test_sync_group_aborts_both_players_before_alignment(self):
        master = SimulatedDr47Device(sync_role="master")
        slave = SimulatedDr47Device(sync_role="slave")
        master.connect()
        slave.connect()
        master.playback_armed = master.playback_prepared = master.playback_running = True
        slave.playback_armed = slave.playback_prepared = slave.playback_running = True

        SyncGroup(master, slave, timeout_s=0.2, poll_interval_s=0.001).sync(epoch=1)

        for board in (master, slave):
            status = board.status().capabilities
            self.assertFalse(status.playback_armed)
            self.assertFalse(status.playback_prepared)
            self.assertFalse(status.playback_running)

    def test_sync_group_reports_slave_alignment_failure(self):
        class FailingSlave(SimulatedDr47Device):
            def _simulate_external_sync(self, epoch=1):
                self._sim_sync_seen = True
                self._sim_sync_ready = False
                self._sim_sync_align_busy = True
                self._sim_sync_align_failed = True
                self._sim_sync_alignment_error = 0x1234

        master = SimulatedDr47Device(sync_role="master")
        slave = FailingSlave(sync_role="slave")
        master.connect()
        slave.connect()
        with self.assertRaisesRegex(SynchronizationError, "slave DAC alignment failed"):
            SyncGroup(master, slave, timeout_s=0.05, poll_interval_s=0.001).sync()

    def test_sync_group_rejects_skipped_alignment_epoch(self):
        class SkippedEpochSlave(SimulatedDr47Device):
            def _simulate_external_sync(self, epoch=1):
                super()._simulate_external_sync(epoch)
                self._sim_sync_alignment_epoch = (
                    self._sim_sync_alignment_epoch + 1
                ) & 0x3F

        master = SimulatedDr47Device(sync_role="master")
        slave = SkippedEpochSlave(sync_role="slave")
        master.connect()
        slave.connect()
        with self.assertRaisesRegex(SynchronizationError, "alignment epoch mismatch"):
            SyncGroup(master, slave, timeout_s=0.02, poll_interval_s=0.001).sync()

    def test_sync_group_rejects_bypass_mode(self):
        master = SimulatedDr47Device(sync_role="master")
        slave = SimulatedDr47Device(sync_role="slave")
        master.connect()
        slave.connect()
        slave.bypass_sync()
        with self.assertRaises(SynchronizationError):
            SyncGroup(master, slave, timeout_s=0.05).sync()


if __name__ == "__main__":
    unittest.main()
