"""Capability and status value objects returned by the driver."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class PlaybackState(str, Enum):
    IDLE = "idle"
    ARMED = "armed"
    PREPARED = "prepared"
    RUNNING = "running"
    FAULT = "fault"


@dataclass(frozen=True)
class RfdcChannelReadback:
    channel: int
    nco_hz: int = 0
    nyquist_zone: int = 1
    nco_phase_deg: float = 0.0
    dac_output_current_ma: float = 20.0
    status: int = 0
    nco_word: int = 0
    phase_word: int = 0
    vop_code: int = 0


@dataclass(frozen=True)
class DeviceCapabilities:
    """HELLO/STATUS information cached by :class:`Dr47Device`."""

    device_uid: str = ""
    protocol_version: int = 0
    build_profile_id: int = 0
    build_profile: str = ""
    source_commit_id: int = 0
    trigger_path_version: int = 0
    capability_bits: int = 0
    state_flags: int = 0
    rfdc_ready: bool = False
    dac_mts_required: bool = False
    dac_mts_ready: bool = False
    dac_mts_failed: bool = False
    dac_mts_tile_mask: int = 0
    dac_mts_error: int = 0
    nco_sync_ready: bool = False
    nco_sync_epoch: int = 0
    sync_role: str = "slave"
    sync_mode: str = "external"
    sync_seen: bool = False
    sync_link_ready: bool = False
    # Runtime strict-alignment state.  These fields are zero/default when a
    # legacy board returns the pre-alignment (96-byte) STATUS payload.
    sync_align_busy: bool = False
    sync_align_failed: bool = False
    sync_alignment_epoch: int = 0
    sync_alignment_error: int = 0
    trigger_input_count: int = 0
    trigger_accepted_count: int = 0
    trigger_output_count: int = 0
    ext_trigger_phase_slot: int = 0
    ext_trigger_phase_valid: bool = False
    ext_trigger_phase_overflow: bool = False
    ext_trigger_phase_metastable: bool = False
    ext_trigger_tap_index: int = 0
    ext_trigger_phase_ps_x10: int = 0
    playback_admitted_count: int = 0
    playback_skipped_count: int = 0
    config_valid_mask: int = 0
    playback_state: PlaybackState = PlaybackState.IDLE
    playback_armed: bool = False
    playback_prepared: bool = False
    playback_running: bool = False
    rfdc_readback: tuple[RfdcChannelReadback, ...] = field(default_factory=tuple)
    raw: dict[str, Any] = field(default_factory=dict, compare=False, repr=False)

    @property
    def online(self) -> bool:
        return self.protocol_version > 0

    def has(self, capability: int) -> bool:
        return bool(self.capability_bits & int(capability))


@dataclass(frozen=True)
class DeviceStatus:
    """A stable snapshot returned by :meth:`Dr47Device.status`."""

    connected: bool
    ip: str
    port: int
    state: PlaybackState
    capabilities: DeviceCapabilities
    message: str = ""
    raw: dict[str, Any] = field(default_factory=dict, compare=False, repr=False)

    @property
    def online(self) -> bool:
        return self.connected


@dataclass(frozen=True)
class DiagnosticsSnapshot:
    """Register-priority, hardware-latched playback/trigger diagnostics."""

    generation: int = 0
    trigger_input_count: int = 0
    dac_direct_input_count: int = 0
    dac_direct_accept_count: int = 0
    dac_direct_trigger_pulse: bool = False
    dac_trigger_launch: bool = False
    prepared_dac: bool = False
    output_permitted_dac: bool = False
    trigger_capture_tick: int = 0
    trigger_accepted_count: int = 0
    trigger_skipped_count: int = 0
    trigger_rejected_count: int = 0
    trigger_launch_tick: int = 0
    playback_start_tick: int = 0
    first_valid_tick: int = 0
    trigger_to_launch_last: int = 0
    launch_to_first_valid_last: int = 0
    replay_ready: bool = False
    replay_active: bool = False
    fifo_level: tuple[int, ...] = field(default_factory=tuple)
    underflow_mask: int = 0
    mute: bool = False
    abort: bool = False
    rfdc_status: int = 0
    rfdc_failure_stage: int = 0
    rfdc_failure_address: int = 0
    rfdc_axi_response: int = 0
    dma_chunk_beats: int = 0
    dma_outstanding_beats: int = 0
    refill_start_tick: int = 0
    refill_done_tick: int = 0
    raw: dict[str, Any] = field(default_factory=dict, compare=False, repr=False)


__all__ = ["PlaybackState", "RfdcChannelReadback", "DeviceCapabilities", "DeviceStatus", "DiagnosticsSnapshot"]
