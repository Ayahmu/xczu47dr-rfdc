"""In-memory board simulator used by tests and the web console simulation mode."""

from __future__ import annotations

import struct
from typing import Any, Mapping

import numpy as np

from .capabilities import DeviceCapabilities, DeviceStatus, PlaybackState
from .device import Dr47Device
from .protocol import (
    RF2_CAP_DAC_MTS,
    RF2_CAP_NCO_SYNC,
    RF2_CAP_SYNC_IO,
    RF2_CAP_TRIGGER_IO,
    RF2_CAP_PL_RFDC_CONFIG,
    RF2_CAP_RFDC_GET_CONFIG,
    RF2_OP_ABORT_MUTE,
    RF2_OP_ARM,
    RF2_OP_HELLO,
    RF2_OP_RFDC_APPLY,
    RF2_OP_RFDC_GET_CONFIG,
    RF2_OP_STATUS,
    RF2_OP_TRIGGER,
    RF2_OP_SYNC_EPOCH,
    RF2_OP_SET_SYNC_ROLE,
    RF2_OP_EMIT_TRIGGER,
    RF2_SYNC_MODE_EXTERNAL,
    RF2_SYNC_MODE_BYPASS,
    RF2_SYNC_ROLE_MASTER,
    RF2_SYNC_ROLE_SLAVE,
    RF2_SYNC_STATUS_READY,
    RF2_SYNC_STATUS_ROLE_MASTER,
    RF2_SYNC_STATUS_SEEN,
    RF2_SYNC_STATUS_BYPASS,
    RF2_STATUS_DAC_MTS_READY,
    RF2_STATUS_DAC_MTS_REQUIRED,
    RF2_STATUS_NCO_SYNC_READY,
    RF2_STATUS_OK,
    RF2_STATUS_PREPARED,
    RF2_STATUS_RFDC_READY,
    RF2_STATUS_ARMED,
    RF2_STATUS_RUNNING,
    RFCTRL2_VERSION,
    parse_rfctrl2_rfdc_config_response,
)


class SimulatedDr47Device(Dr47Device):
    """A deterministic simulator with the same public API as ``Dr47Device``."""

    def __init__(self, *args, device_uid: str = "sim-xczu47dr", sync_role: str = "master", **kwargs) -> None:
        if sync_role not in {"master", "slave"}:
            raise ValueError("sync_role must be 'master' or 'slave'")
        kwargs["sync_role"] = sync_role
        kwargs["transport"] = object()
        super().__init__(*args, **kwargs)
        self.device_uid = str(device_uid)
        self.waveforms: dict[int, np.ndarray] = {}
        self.sequences: dict[int, Any] = {}
        self.playback_armed = False
        self.playback_prepared = False
        self.playback_running = False
        self._sim_revision = 0
        self._sim_valid_mask = 0
        self._sim_last_response: dict[str, Any] = {}
        self._trigger_input_count = 0
        self._trigger_accepted_count = 0
        self._trigger_output_count = 0
        self._sim_sync_seen = False
        self._sim_sync_ready = sync_role == "master"

    def _make_status_payload(self) -> bytes:
        capabilities = (RF2_CAP_PL_RFDC_CONFIG | RF2_CAP_RFDC_GET_CONFIG |
                        RF2_CAP_DAC_MTS | RF2_CAP_NCO_SYNC |
                        RF2_CAP_SYNC_IO | RF2_CAP_TRIGGER_IO)
        state_flags = RF2_STATUS_RFDC_READY | RF2_STATUS_DAC_MTS_READY | RF2_STATUS_DAC_MTS_REQUIRED | RF2_STATUS_NCO_SYNC_READY
        if self.playback_armed:
            state_flags |= RF2_STATUS_ARMED | RF2_STATUS_PREPARED
        if self.playback_running:
            state_flags |= RF2_STATUS_RUNNING
        base = struct.pack(
            "<IIIIIIIIQQQQII",
            capabilities, state_flags, self._sim_valid_mask, self._sim_revision,
            0, 0, 0, 0,
            self._channel_mask & 0xFF, 0,
            self._sim_valid_mask & 0xFF, 0,
            1, 0,
        )
        sync_status = 0
        if self._sim_sync_seen:
            sync_status |= RF2_SYNC_STATUS_SEEN
        if self._sim_sync_ready:
            sync_status |= RF2_SYNC_STATUS_READY
        if self._sync_mode == "bypass":
            sync_status |= RF2_SYNC_STATUS_BYPASS
        if self._sync_role == "master":
            sync_status |= RF2_SYNC_STATUS_ROLE_MASTER
        return base + struct.pack(
            "<QIIII", sync_status, self._trigger_input_count,
            self._trigger_accepted_count, self._trigger_output_count, 0,
        )

    def _response(self, opcode: int, payload: bytes = b"", seq: int = 1, status: int = RF2_STATUS_OK) -> dict[str, Any]:
        return {
            "version": RFCTRL2_VERSION,
            "status": int(status),
            "opcode": int(opcode),
            "seq": int(seq) & 0xFFFFFFFF,
            "payload_bytes": len(payload),
            "payload": payload,
        }

    def connect(self) -> int:
        self._closed = False
        self._connected = True
        self._capabilities = DeviceCapabilities(
            device_uid=self.device_uid,
            protocol_version=RFCTRL2_VERSION,
            build_profile_id=1,
            build_profile="simulated_xczu47dr",
            capability_bits=(RF2_CAP_PL_RFDC_CONFIG | RF2_CAP_RFDC_GET_CONFIG |
                              RF2_CAP_DAC_MTS | RF2_CAP_NCO_SYNC |
                              RF2_CAP_SYNC_IO | RF2_CAP_TRIGGER_IO),
            state_flags=RF2_STATUS_RFDC_READY | RF2_STATUS_DAC_MTS_READY | RF2_STATUS_DAC_MTS_REQUIRED | RF2_STATUS_NCO_SYNC_READY,
            rfdc_ready=True,
            dac_mts_required=True,
            dac_mts_ready=True,
            nco_sync_ready=True,
            sync_role=self._sync_role,
            sync_mode=self._sync_mode,
            sync_seen=self._sim_sync_seen,
            sync_link_ready=self._sim_sync_ready,
            trigger_input_count=self._trigger_input_count,
            trigger_accepted_count=self._trigger_accepted_count,
            trigger_output_count=self._trigger_output_count,
            config_valid_mask=self._sim_valid_mask,
            raw={"device_uid": self.device_uid},
        )
        self._status = DeviceStatus(True, self.ip, self.port, PlaybackState.IDLE, self._capabilities, "simulation mode")
        return 0

    def status(self, refresh: bool = True) -> DeviceStatus:
        state = PlaybackState.RUNNING if self.playback_running else PlaybackState.ARMED if self.playback_armed else PlaybackState.IDLE
        self._capabilities = DeviceCapabilities(
            **{**self._capabilities.__dict__,
               "config_valid_mask": self._sim_valid_mask,
               "playback_state": state,
               "playback_armed": self.playback_armed,
               "playback_prepared": self.playback_prepared,
               "playback_running": self.playback_running,
               "sync_role": self._sync_role,
               "sync_mode": self._sync_mode,
               "sync_seen": self._sim_sync_seen,
               "sync_link_ready": self._sim_sync_ready,
               "trigger_input_count": self._trigger_input_count,
               "trigger_accepted_count": self._trigger_accepted_count,
               "trigger_output_count": self._trigger_output_count,
               "raw": {"device_uid": self.device_uid, "config_valid_mask": self._sim_valid_mask}},
        )
        self._status = DeviceStatus(self.connected, self.ip, self.port, state, self._capabilities, "simulation mode")
        return self._status

    def rfctrl2_hello(self, seq: int | None = None, wait_response: bool = True):
        return self._response(RF2_OP_HELLO, self._make_status_payload(), seq or 1)

    def rfctrl2_status(self, seq: int | None = None, wait_response: bool = True, retries: int | None = None):
        return self._response(RF2_OP_STATUS, self._make_status_payload(), seq or 1)

    def rfctrl2_set_sync_role(self, role: int, mode: int = RF2_SYNC_MODE_EXTERNAL,
                              seq: int | None = None, wait_response: bool = True):
        requested_role = "master" if int(role) == RF2_SYNC_ROLE_MASTER else "slave"
        if requested_role != self._sync_role or self.playback_armed or self.playback_prepared or self.playback_running:
            return self._response(RF2_OP_SET_SYNC_ROLE, seq=seq or 1, status=3)
        self._sync_mode = "bypass" if int(mode) == RF2_SYNC_MODE_BYPASS else "external"
        self._sim_sync_seen = False
        self._sim_sync_ready = self._sync_role == "master" or self._sync_mode == "bypass"
        return self._response(RF2_OP_SET_SYNC_ROLE, self._make_status_payload(), seq or 1)

    def rfctrl2_sync_epoch(self, epoch: int, seq: int | None = None, wait_response: bool = True):
        if self._sync_role != "master":
            return self._response(RF2_OP_SYNC_EPOCH, seq=seq or 1, status=6)
        self._sim_sync_seen = True
        self._sim_sync_ready = True
        return self._response(RF2_OP_SYNC_EPOCH, self._make_status_payload(), seq or 1)

    def rfctrl2_emit_trigger(self, seq: int | None = None, wait_response: bool = True):
        self._trigger_output_count = (self._trigger_output_count + 1) & 0xFFFFFFFF
        # Model the documented XS18 -> XS19 loopback and its synchronization
        # gate. A master is always locally ready.
        if self.playback_armed:
            self._trigger_input_count = (self._trigger_input_count + 1) & 0xFFFFFFFF
            if self._sim_sync_ready:
                self._trigger_accepted_count = (self._trigger_accepted_count + 1) & 0xFFFFFFFF
                self.playback_running = True
        return self._response(RF2_OP_EMIT_TRIGGER, self._make_status_payload(), seq or 1)

    def rfctrl2_rfdc_apply(self, per_channel_nco_hz, per_channel_nyquist_zone, per_channel_phase_deg,
                           per_channel_output_current_ma, revision: int, channel_mask: int = 0xFF,
                           seq: int | None = None, wait_response: bool = True, retries: int | None = None):
        self._sim_revision = int(revision) & 0xFFFFFFFF
        self._sim_valid_mask |= int(channel_mask) & 0xFF
        for channel in range(1, 9):
            self._pending_nco[channel] = _value(per_channel_nco_hz, channel, 0.0)
            self._pending_zone[channel] = _value(per_channel_nyquist_zone, channel, 1)
            self._pending_phase[channel] = _value(per_channel_phase_deg, channel, 0.0)
            self._pending_current[channel] = _value(per_channel_output_current_ma, channel, 20.0)
        return parse_rfctrl2_rfdc_config_response(
            self._response(RF2_OP_RFDC_APPLY, self._make_config_payload(), seq or 1)
        )

    def _make_config_payload(self) -> bytes:
        header = struct.pack("<IIIIIIII", self._sim_revision, self._sim_valid_mask, 0, self._sim_valid_mask, 0, 0, 0, RF2_STATUS_RFDC_READY)
        entries = bytearray()
        for channel in range(1, 9):
            entries += struct.pack(
                "<qIiIIQII", int(round(self._pending_nco[channel])), int(self._pending_zone[channel]),
                int(round(self._pending_phase[channel] * 1000)), int(round(self._pending_current[channel] * 1000)),
                0, 0, 0, 0,
            )
        return header + bytes(entries)

    def rfctrl2_rfdc_get_config(self, seq: int | None = None, wait_response: bool = True, retries: int | None = None):
        return parse_rfctrl2_rfdc_config_response(
            self._response(RF2_OP_RFDC_GET_CONFIG, self._make_config_payload(), seq or 1)
        )

    def rfctrl2_arm(self, run_id: int, channel_mask: int = 0xFF, seq: int | None = None, wait_response: bool = True):
        if int(channel_mask) & ~self._sim_valid_mask:
            return self._response(RF2_OP_ARM, seq=seq or 1, status=5)
        self.playback_armed = True
        self.playback_prepared = True
        self.playback_running = False
        return self._response(RF2_OP_ARM, self._make_status_payload(), seq or 1)

    def rfctrl2_trigger(self, seq: int | None = None, wait_response: bool = True):
        if not self.playback_armed or not self._sim_sync_ready:
            return self._response(RF2_OP_TRIGGER, seq=seq or 1, status=6)
        self.playback_running = True
        return self._response(RF2_OP_TRIGGER, self._make_status_payload(), seq or 1)

    def rfctrl2_abort_mute(self, seq: int | None = None, wait_response: bool = True):
        self.playback_armed = self.playback_prepared = self.playback_running = False
        return self._response(RF2_OP_ABORT_MUTE, self._make_status_payload(), seq or 1)

    def upload_waveforms(self, channel_waves, channel_sequences=None, **kwargs):
        for channel, wave in channel_waves.items():
            fmt = (kwargs.get("wave_formats") or {}).get(int(channel))
            from .waveforms import ezq_wave_to_interleaved_int16
            if fmt is None:
                arr = np.asarray(wave)
                if arr.ndim == 2:
                    fmt = "iq_matrix"
                elif isinstance(wave, (list, tuple)) and arr.size and all(-32768 <= int(item) <= 32767 for item in arr.reshape(-1).tolist()):
                    fmt = "interleaved_iq"
                else:
                    fmt = "packed_iq"
            self.waveforms[int(channel)] = ezq_wave_to_interleaved_int16(wave, fmt)
        if channel_sequences:
            self.sequences.update({int(channel): sequence for channel, sequence in channel_sequences.items()})
        self._uploaded_channels.update(int(channel) for channel in channel_waves)
        return {"packet_count": 0, "channels": tuple(sorted(int(channel) for channel in channel_waves)), "simulated": True}

    def close(self) -> None:
        self._closed = True
        self._connected = False
        self._status = DeviceStatus(False, self.ip, self.port, PlaybackState.IDLE, self._capabilities, "closed")


def _value(mapping: Mapping | list | tuple, channel: int, default):
    if isinstance(mapping, Mapping):
        return mapping.get(channel, mapping.get(f"ch{channel}", default))
    values = list(mapping)
    return values[channel - 1] if len(values) == 8 else default


__all__ = ["SimulatedDr47Device"]
