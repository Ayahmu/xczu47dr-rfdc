"""Strict two-board synchronization orchestration.

``Dr47Device.sync()`` remains the low-level master pulse API.  Applications
that need the DAC MTS/NCO re-alignment contract should use ``SyncGroup`` so a
single call also stops both players and waits for both boards to acknowledge
the new hardware synchronization epoch.
"""

from __future__ import annotations

import time
from dataclasses import dataclass

from .errors import SynchronizationError
from .protocol import (
    RF2_CAP_DAC_MTS,
    RF2_CAP_NCO_SYNC,
    RF2_CAP_SYNC_IO,
    RF2_CAP_TRIGGER_IO,
)


@dataclass(frozen=True)
class SyncAlignmentResult:
    requested_epoch: int
    master_alignment_epoch: int
    slave_alignment_epoch: int
    master_sync_seen: bool
    slave_sync_seen: bool
    master_mts_ready: bool
    slave_mts_ready: bool
    master_nco_ready: bool
    slave_nco_ready: bool
    elapsed_s: float


def _next_epoch(previous: int) -> int:
    """Return the exact next six-bit hardware epoch, including wrap."""

    return (int(previous) + 1) & 0x3F


class SyncGroup:
    """Coordinate strict runtime alignment for one master and one slave."""

    def __init__(self, master, slave, timeout_s: float = 5.0, poll_interval_s: float = 0.01) -> None:
        self.master = master
        self.slave = slave
        self.timeout_s = float(timeout_s)
        self.poll_interval_s = float(poll_interval_s)
        if self.timeout_s <= 0 or self.poll_interval_s <= 0:
            raise ValueError("timeout_s and poll_interval_s must be positive")

    def _status(self, device):
        return device.status(refresh=True).capabilities

    def sync(self, epoch: int = 1) -> SyncAlignmentResult:
        """Abort, emit XS20 SYNC, and wait for both boards to re-align.

        The uploaded waveform is intentionally retained by ``abort_mute``;
        callers must ARM again after this method returns successfully.
        """

        started = time.monotonic()
        master_caps = self._status(self.master)
        slave_caps = self._status(self.slave)
        if master_caps.sync_role != "master":
            raise SynchronizationError(f"master device reports role {master_caps.sync_role!r}")
        if slave_caps.sync_role != "slave":
            raise SynchronizationError(f"slave device reports role {slave_caps.sync_role!r}")
        if master_caps.sync_mode != "external" or slave_caps.sync_mode != "external":
            raise SynchronizationError("strict SyncGroup.sync() requires external mode on both boards")
        required_capabilities = (
            RF2_CAP_DAC_MTS | RF2_CAP_NCO_SYNC |
            RF2_CAP_SYNC_IO | RF2_CAP_TRIGGER_IO
        )
        for name, caps in (("master", master_caps), ("slave", slave_caps)):
            missing = required_capabilities & ~caps.capability_bits
            if missing:
                raise SynchronizationError(
                    f"{name} is missing strict synchronization capabilities "
                    f"0x{missing:08X} (advertised=0x{caps.capability_bits:08X})"
                )

        master_before = master_caps.sync_alignment_epoch
        slave_before = slave_caps.sync_alignment_epoch
        master_expected = _next_epoch(master_before)
        slave_expected = _next_epoch(slave_before)
        self.master.abort_mute()
        self.slave.abort_mute()
        # Do not start an alignment transaction while either PL executor still
        # reports a stale running/armed state after ABORT_MUTE.
        post_abort_master = self._status(self.master)
        post_abort_slave = self._status(self.slave)
        if (post_abort_master.playback_running or post_abort_master.playback_armed or
                post_abort_slave.playback_running or post_abort_slave.playback_armed):
            raise SynchronizationError("synchronization started while playback was still active")
        try:
            self.master.sync(epoch=int(epoch))
        except Exception as exc:
            raise SynchronizationError(f"master did not emit SYNC: {exc}") from exc

        # The real slave receives this over XS20.  This hook only makes the
        # in-memory simulator deterministic and has no effect on hardware.
        receive = getattr(self.slave, "_simulate_external_sync", None)
        if receive is not None:
            receive(int(epoch))

        deadline = started + self.timeout_s
        last_master = master_caps
        last_slave = slave_caps
        while time.monotonic() < deadline:
            last_master = self._status(self.master)
            last_slave = self._status(self.slave)
            if last_master.sync_align_failed:
                raise SynchronizationError(
                    f"master DAC alignment failed: error=0x{last_master.sync_alignment_error:04X}"
                )
            if last_slave.sync_align_failed:
                raise SynchronizationError(
                    f"slave DAC alignment failed: error=0x{last_slave.sync_alignment_error:04X}"
                )
            if not last_slave.sync_seen:
                time.sleep(self.poll_interval_s)
                continue
            if last_master.sync_align_busy or last_slave.sync_align_busy:
                time.sleep(self.poll_interval_s)
                continue
            if last_master.sync_alignment_epoch != master_expected:
                time.sleep(self.poll_interval_s)
                continue
            if last_slave.sync_alignment_epoch != slave_expected:
                time.sleep(self.poll_interval_s)
                continue
            if not (last_master.dac_mts_ready and last_slave.dac_mts_ready):
                time.sleep(self.poll_interval_s)
                continue
            if not (last_master.nco_sync_ready and last_slave.nco_sync_ready):
                time.sleep(self.poll_interval_s)
                continue
            if not (last_master.sync_link_ready and last_slave.sync_link_ready):
                time.sleep(self.poll_interval_s)
                continue
            return SyncAlignmentResult(
                requested_epoch=int(epoch),
                master_alignment_epoch=last_master.sync_alignment_epoch,
                slave_alignment_epoch=last_slave.sync_alignment_epoch,
                master_sync_seen=last_master.sync_seen,
                slave_sync_seen=last_slave.sync_seen,
                master_mts_ready=last_master.dac_mts_ready,
                slave_mts_ready=last_slave.dac_mts_ready,
                master_nco_ready=last_master.nco_sync_ready,
                slave_nco_ready=last_slave.nco_sync_ready,
                elapsed_s=time.monotonic() - started,
            )
        if last_master.sync_align_busy or last_slave.sync_align_busy:
            reason = "alignment timeout"
        elif not last_slave.sync_seen:
            reason = "slave did not receive XS20 SYNC"
        elif (last_master.sync_alignment_epoch != master_expected or
              last_slave.sync_alignment_epoch != slave_expected):
            reason = (
                "alignment epoch mismatch: "
                f"master expected={master_expected} actual={last_master.sync_alignment_epoch}, "
                f"slave expected={slave_expected} actual={last_slave.sync_alignment_epoch}"
            )
        else:
            reason = "MTS/NCO readiness or sync_link_ready did not complete"
        raise SynchronizationError(f"strict synchronization failed: {reason}")


__all__ = ["SyncGroup", "SyncAlignmentResult"]
