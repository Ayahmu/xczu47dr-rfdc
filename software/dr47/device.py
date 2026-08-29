"""Public 47DR board object and direct RFCTRL2 control API.

The public driver API expresses RF frequencies in GHz.  RFCTRL2 still carries
signed integer Hz on the wire, so conversion is kept at this module boundary.
"""

from __future__ import annotations

import math
import threading
import time
from collections.abc import Mapping, Sequence
from dataclasses import replace
from typing import Any, Literal

import numpy as np

from .capabilities import DeviceCapabilities, DeviceStatus, PlaybackState, RfdcChannelReadback
from .errors import (
    ConnectionError,
    ConnectionStateError,
    DeviceBusyError,
    DeviceNotReadyError,
    DeviceStatusError,
    ParameterRangeError,
    ProtocolVersionError,
    UnsupportedCapabilityError,
    UnsupportedParameterError,
    SynchronizationError,
    TransportTimeout,
)
from .protocol import *  # noqa: F401,F403 - protocol constants are part of the public API
from .protocol import (
    RF2_CAP_DAC_MTS,
    RF2_CAP_NCO_SYNC,
    RF2_CAP_SYNC_IO,
    RF2_CAP_TRIGGER_IO,
    RF2_CAP_PL_RFDC_CONFIG,
    RF2_STATUS_BAD_VERSION,
    RF2_STATUS_BUSY,
    RF2_STATUS_OK,
    RF2_STATUS_RFDC_NOT_READY,
    RF2_STATUS_UNSUPPORTED,
    RF2_STATUS_RANGE,
    RF2_SYNC_MODE_EXTERNAL,
    RF2_SYNC_MODE_BYPASS,
    RF2_SYNC_ROLE_MASTER,
    RF2_SYNC_ROLE_SLAVE,
    pack_rfctrl2_abort_mute,
    pack_rfctrl2_arm,
    pack_rfctrl2_hello,
    pack_rfctrl2_network_apply,
    pack_rfctrl2_network_get,
    pack_rfctrl2_network_restart,
    pack_rfctrl2_rfdc_apply,
    pack_rfctrl2_rfdc_get_config,
    pack_rfctrl2_start_at,
    pack_rfctrl2_set_sync_role,
    pack_rfctrl2_emit_trigger,
    pack_rfctrl2_status,
    pack_rfctrl2_sync_epoch,
    pack_rfctrl2_trigger,
    parse_rfctrl2_network_response,
    parse_rfctrl2_rfdc_config_response,
    parse_rfctrl2_status_payload,
    parse_rfresp2_packet,
)
from .transport import UdpTransport
from .waveforms import (
    DEFAULT_DDR_LAYOUT,
    DDR_LAYOUT_INTERLEAVED_512B,
    PLAY_FLAG_INTERLEAVED,
    ezq_wave_to_interleaved_int16,
    iter_interleaved_udp_waveform_packets,
    pack_udp_instruction_packet,
    sequence_to_play_commands,
    waveform_length_bytes,
)


GHZ_TO_HZ = 1_000_000_000.0
RFDC_NCO_MIN_GHZ = RFDC_NCO_MIN_HZ / GHZ_TO_HZ
RFDC_NCO_MAX_GHZ = RFDC_NCO_MAX_HZ / GHZ_TO_HZ


def ghz_to_hz(value_ghz: float) -> float:
    """Convert a public GHz value to the Hz unit used by RFCTRL2."""

    value = float(value_ghz)
    if not math.isfinite(value):
        raise ParameterRangeError(f"frequency must be finite, got {value_ghz!r} GHz")
    return value * GHZ_TO_HZ


def hz_to_ghz(value_hz: float) -> float:
    """Convert an RFCTRL2 Hz value to the public GHz unit."""

    value = float(value_hz)
    if not math.isfinite(value):
        raise ParameterRangeError(f"frequency must be finite, got {value_hz!r} Hz")
    return value / GHZ_TO_HZ


def rfdc_nco_plan_for_target(target_rf_ghz: float, dac_fs_ghz: float = 6.4) -> dict[str, float | int | str]:
    """Map an analog RF target in GHz to the RFDC NCO and Nyquist zone.

    The returned values are also in GHz.  The RFCTRL2 packet conversion is
    performed only when the plan is applied to a device.
    """

    target = float(target_rf_ghz)
    fs = float(dac_fs_ghz)
    if not math.isfinite(target) or not math.isfinite(fs) or fs <= 0.0:
        raise ParameterRangeError("target RF frequency must be finite and DAC sample rate must be positive GHz values")
    if not 0.0 <= target <= fs:
        raise ParameterRangeError(f"target RF frequency must be in [0, Fs], got {target:g} GHz for Fs={fs:g} GHz")
    if target < fs / 2.0:
        return {"target_rf_ghz": target, "nco_ghz": target, "nyquist_zone": 1, "image": "direct"}
    return {"target_rf_ghz": target, "nco_ghz": round(target - fs, 12), "nyquist_zone": 2, "image": "zone2"}


class Dr47Device:
    """One object controls one XCZU47DR board over UDP."""

    def __init__(
        self,
        ip: str = "192.168.1.128",
        port: int = 1234,
        timeout_s: float = 5.0,
        udp_interface: str = "",
        udp_source_ip: str = "",
        retries: int = 2,
        batch_mode: bool = False,
        sync_role: Literal["master", "slave"] = "slave",
        transport: object | None = None,
    ) -> None:
        self.ip = str(ip)
        self.port = int(port)
        self.timeout_s = float(timeout_s)
        self.udp_interface = str(udp_interface or "")
        self.udp_source_ip = str(udp_source_ip or "")
        self.retries = max(0, int(retries))
        self.batch_mode = bool(batch_mode)
        if sync_role not in {"master", "slave"}:
            raise ValueError("sync_role must be 'master' or 'slave'")
        self._transport = transport
        self._owns_transport = transport is None
        self._connected = False
        self._closed = False
        self._lock = threading.RLock()
        self._sequence = int(time.time_ns()) & 0xFFFFFFFF or 1
        self._run_id = 1
        self._channel_mask = 0
        self._mask_explicit = False
        self._uploaded_channels: set[int] = set()
        self._pending_nco = {channel: 0.0 for channel in range(1, 9)}
        self._pending_zone = {channel: 1 for channel in range(1, 9)}
        self._pending_phase = {channel: 0.0 for channel in range(1, 9)}
        self._pending_current = {channel: 20.0 for channel in range(1, 9)}
        self._pending_revision = 0
        self._capabilities = DeviceCapabilities()
        self._sync_role = sync_role
        self._sync_mode = "external"
        self._status = DeviceStatus(False, self.ip, self.port, PlaybackState.IDLE, self._capabilities, "not connected")

    @property
    def capabilities(self) -> DeviceCapabilities:
        return self._capabilities

    @property
    def connected(self) -> bool:
        return self._connected and not self._closed

    @property
    def transport(self):
        if self._transport is None:
            self._transport = UdpTransport(
                self.ip,
                self.port,
                timeout_s=self.timeout_s,
                udp_interface=self.udp_interface,
                udp_source_ip=self.udp_source_ip,
            )
            self._owns_transport = True
        return self._transport

    def _next_sequence(self) -> int:
        value = self._sequence
        self._sequence = 1 if self._sequence == 0xFFFFFFFF else self._sequence + 1
        return value

    def _request(self, packet: bytes, opcode: int, seq: int, *, wait_response: bool = True, retries: int | None = None):
        try:
            if hasattr(self.transport, "request"):
                return self.transport.request(
                    packet,
                    seq=int(seq),
                    opcode=int(opcode),
                    retries=self.retries if retries is None else int(retries),
                    wait_response=wait_response,
                )
            # A minimal injected transport can expose send/receive separately.
            self.transport.send(packet)
            if not wait_response:
                return len(packet)
            return self.transport.receive_rfresp2(expected_seq=seq, expected_opcode=opcode)
        except TransportTimeout:
            raise
        except (TimeoutError, OSError) as exc:
            raise ConnectionError(f"RFCTRL2 request to {self.ip}:{self.port} failed: {exc}") from exc

    @staticmethod
    def _check_response(response: Mapping, operation: str) -> Mapping:
        if not isinstance(response, Mapping):
            raise DeviceStatusError(operation, 0xFFFF, "RFCTRL2 did not return a response")
        version = int(response.get("version", 0))
        if version != RFCTRL2_VERSION:
            raise ProtocolVersionError(
                f"RFCTRL2 {operation} returned protocol version {version}; expected {RFCTRL2_VERSION}"
            )
        status = int(response.get("status", RF2_STATUS_BAD_REQUEST))
        if status == RF2_STATUS_OK:
            return response
        if status == RF2_STATUS_BAD_VERSION:
            raise ProtocolVersionError(f"RFCTRL2 {operation} rejected protocol version")
        if status == RF2_STATUS_BUSY:
            raise DeviceBusyError(operation, status)
        if status == RF2_STATUS_RFDC_NOT_READY:
            raise DeviceNotReadyError(operation, status)
        if status == RF2_STATUS_UNSUPPORTED:
            raise UnsupportedCapabilityError(operation, "RFCTRL2 capability", int(response.get("capabilities", 0)))
        if status == RF2_STATUS_RANGE:
            raise ParameterRangeError(f"RFCTRL2 {operation} rejected a parameter range")
        raise DeviceStatusError(operation, status)

    def _update_from_status(self, response: Mapping) -> DeviceCapabilities:
        decoded = parse_rfctrl2_status_payload(response)
        state_flags = int(decoded.get("state_flags", 0))
        if decoded.get("running"):
            state = PlaybackState.RUNNING
        elif decoded.get("prepared"):
            state = PlaybackState.PREPARED
        elif decoded.get("armed"):
            state = PlaybackState.ARMED
        else:
            state = PlaybackState.IDLE
        self._capabilities = DeviceCapabilities(
            device_uid=str(decoded.get("device_uid", self._capabilities.device_uid)),
            protocol_version=int(response.get("version", RFCTRL2_VERSION)),
            build_profile_id=int(decoded.get("build_profile_id", self._capabilities.build_profile_id)),
            build_profile=str(decoded.get("build_profile", self._capabilities.build_profile)),
            capability_bits=int(decoded.get("capabilities", 0)),
            state_flags=state_flags,
            rfdc_ready=bool(decoded.get("rfdc_ready")),
            dac_mts_required=bool(decoded.get("dac_mts_required")),
            dac_mts_ready=bool(decoded.get("dac_mts_ready")),
            dac_mts_failed=bool(decoded.get("dac_mts_failed")),
            dac_mts_tile_mask=int(decoded.get("dac_mts_tile_mask", 0)) & 0xF,
            dac_mts_error=int(decoded.get("dac_mts_error", 0)) & 0xFFFF,
            nco_sync_ready=bool(decoded.get("nco_sync_ready")),
            nco_sync_epoch=int(decoded.get("nco_sync_epoch", 0)) & 0xFFFFFFFF,
            sync_role=str(decoded.get("sync_role", self._sync_role)),
            sync_mode=str(decoded.get("sync_mode", self._sync_mode)),
            sync_seen=bool(decoded.get("sync_seen", False)),
            sync_link_ready=bool(decoded.get("sync_link_ready", False)),
            sync_align_busy=bool(decoded.get("sync_align_busy", False)),
            sync_align_failed=bool(decoded.get("sync_align_failed", False)),
            sync_alignment_epoch=int(decoded.get("sync_alignment_epoch", 0)) & 0x3F,
            sync_alignment_error=int(decoded.get("sync_alignment_error", 0)) & 0xFFFF,
            trigger_input_count=int(decoded.get("trigger_input_count", 0)) & 0xFFFFFFFF,
            trigger_accepted_count=int(decoded.get("trigger_accepted_count", 0)) & 0xFFFFFFFF,
            trigger_output_count=int(decoded.get("trigger_output_count", 0)) & 0xFFFFFFFF,
            config_valid_mask=int(decoded.get("config_valid_mask", 0)) & 0xFF,
            playback_state=state,
            playback_armed=bool(decoded.get("armed")),
            playback_prepared=bool(decoded.get("prepared")),
            playback_running=bool(decoded.get("running")),
            raw=dict(decoded),
        )
        self._status = DeviceStatus(self._connected, self.ip, self.port, state, self._capabilities, "RFCTRL2 online", dict(decoded))
        self._sync_role = self._capabilities.sync_role
        self._sync_mode = self._capabilities.sync_mode
        return self._capabilities

    def connect(self) -> int:
        with self._lock:
            if self._closed:
                raise ConnectionStateError("cannot connect a closed Dr47Device")
            try:
                hello_seq = self._next_sequence()
                hello = self._request(pack_rfctrl2_hello(hello_seq), RF2_OP_HELLO, hello_seq, retries=self.retries)
                self._check_response(hello, "HELLO")
                self._connected = True
                self._update_from_status(hello)
                # STATUS is authoritative when a board returns a short HELLO.
                status_seq = self._next_sequence()
                status = self._request(pack_rfctrl2_status(status_seq), RF2_OP_STATUS, status_seq, retries=self.retries)
                self._check_response(status, "STATUS")
                self._update_from_status(status)
                return 0
            except Exception as exc:
                self._connected = False
                self._status = DeviceStatus(False, self.ip, self.port, PlaybackState.FAULT, self._capabilities, str(exc))
                if isinstance(exc, (ConnectionError, ProtocolVersionError, DeviceStatusError, UnsupportedCapabilityError, TransportTimeout)):
                    raise
                raise ConnectionError(str(exc)) from exc

    def status(self, refresh: bool = True) -> DeviceStatus:
        with self._lock:
            if refresh and self.connected:
                seq = self._next_sequence()
                response = self._request(pack_rfctrl2_status(seq), RF2_OP_STATUS, seq, retries=self.retries)
                self._check_response(response, "STATUS")
                self._update_from_status(response)
            return self._status

    def _require_connected(self) -> None:
        if not self.connected:
            raise ConnectionStateError("Dr47Device.connect() must be called before this operation")

    # Low-level RFCTRL2 methods are used by the web backend and protocol tools.
    def rfctrl2_hello(self, seq: int | None = None, wait_response: bool = True):
        sequence = self._next_sequence() if seq is None else int(seq)
        return self._request(pack_rfctrl2_hello(sequence), RF2_OP_HELLO, sequence, wait_response=wait_response)

    def rfctrl2_status(self, seq: int | None = None, wait_response: bool = True, retries: int | None = None):
        sequence = self._next_sequence() if seq is None else int(seq)
        response = self._request(pack_rfctrl2_status(sequence), RF2_OP_STATUS, sequence, wait_response=wait_response, retries=retries)
        return response

    def rfctrl2_rfdc_apply(self, per_channel_nco_hz, per_channel_nyquist_zone, per_channel_phase_deg,
                           per_channel_output_current_ma, revision: int, channel_mask: int = 0xFF,
                           seq: int | None = None, wait_response: bool = True, retries: int | None = None):
        sequence = self._next_sequence() if seq is None else int(seq)
        response = self._request(
            pack_rfctrl2_rfdc_apply(per_channel_nco_hz, per_channel_nyquist_zone, per_channel_phase_deg,
                                    per_channel_output_current_ma, revision, channel_mask=channel_mask, seq=sequence),
            RF2_OP_RFDC_APPLY, sequence, wait_response=wait_response, retries=retries,
        )
        if not wait_response:
            return response
        self._check_response(response, "RFDC_APPLY")
        result = parse_rfctrl2_rfdc_config_response(response)
        self._cache_rfdc_readback(result)
        return result

    def rfctrl2_rfdc_get_config(self, seq: int | None = None, wait_response: bool = True, retries: int | None = None):
        sequence = self._next_sequence() if seq is None else int(seq)
        response = self._request(pack_rfctrl2_rfdc_get_config(sequence), RF2_OP_RFDC_GET_CONFIG, sequence,
                                 wait_response=wait_response, retries=retries)
        if not wait_response:
            return response
        self._check_response(response, "RFDC_GET_CONFIG")
        result = parse_rfctrl2_rfdc_config_response(response)
        self._cache_rfdc_readback(result)
        return result

    def rfctrl2_arm(self, run_id: int, channel_mask: int = 0xFF, seq: int | None = None, wait_response: bool = True):
        sequence = self._next_sequence() if seq is None else int(seq)
        response = self._request(pack_rfctrl2_arm(run_id, channel_mask, sequence), RF2_OP_ARM, sequence, wait_response=wait_response)
        if wait_response:
            self._check_response(response, "ARM")
        return response

    def rfctrl2_trigger(self, seq: int | None = None, wait_response: bool = True):
        sequence = self._next_sequence() if seq is None else int(seq)
        response = self._request(pack_rfctrl2_trigger(sequence), RF2_OP_TRIGGER, sequence, wait_response=wait_response)
        if wait_response:
            self._check_response(response, "TRIGGER")
        return response

    def rfctrl2_abort_mute(self, seq: int | None = None, wait_response: bool = True):
        sequence = self._next_sequence() if seq is None else int(seq)
        response = self._request(pack_rfctrl2_abort_mute(sequence), RF2_OP_ABORT_MUTE, sequence, wait_response=wait_response)
        if wait_response:
            self._check_response(response, "ABORT_MUTE")
        return response

    def set_sync_role(self, role: str) -> int:
        """Validate the role fixed into this bitstream; it cannot be changed."""

        value = str(role).strip().lower()
        if value not in {"master", "slave"}:
            raise ValueError("sync role must be 'master' or 'slave'")
        fixed_role = self.status(refresh=False).capabilities.sync_role
        if fixed_role not in {"master", "slave"}:
            fixed_role = self.status(refresh=True).capabilities.sync_role
        if value != fixed_role:
            raise SynchronizationError(
                f"bitstream role is fixed as {fixed_role!r}; requested {value!r} requires the other bitstream"
            )
        role_code = RF2_SYNC_ROLE_MASTER if fixed_role == "master" else RF2_SYNC_ROLE_SLAVE
        mode_code = RF2_SYNC_MODE_BYPASS if self._sync_mode == "bypass" else RF2_SYNC_MODE_EXTERNAL
        self._require_connected()
        response = self.rfctrl2_set_sync_role(role_code, mode_code, wait_response=True)
        self._check_response(response, "SET_SYNC_ROLE")
        self._sync_role = fixed_role
        self._capabilities = replace(self._capabilities, sync_role=fixed_role)
        return 0

    def set_sync_mode(self, mode: str) -> int:
        """Select strict external synchronization or explicit local bypass."""

        value = str(mode).strip().lower()
        if value not in {"external", "bypass"}:
            raise ValueError("sync mode must be 'external' or 'bypass'")
        capability_bits = self.status(refresh=False).capabilities.capability_bits
        required_capabilities = RF2_CAP_SYNC_IO | RF2_CAP_TRIGGER_IO
        if (capability_bits & required_capabilities) != required_capabilities:
            raise UnsupportedCapabilityError(
                "SET_SYNC_ROLE requires RFCTRL2 SYNC and Trigger capabilities; "
                f"board capabilities=0x{capability_bits:08X}"
            )
        mode_code = RF2_SYNC_MODE_BYPASS if value == "bypass" else RF2_SYNC_MODE_EXTERNAL
        role_code = RF2_SYNC_ROLE_MASTER if self._sync_role == "master" else RF2_SYNC_ROLE_SLAVE
        self._require_connected()
        response = self.rfctrl2_set_sync_role(role_code, mode_code, wait_response=True)
        self._check_response(response, "SET_SYNC_ROLE")
        self._sync_mode = value
        self.status(refresh=True)
        return 0

    def bypass_sync(self) -> int:
        """Allow a slave to run locally when no XS20 SYNC source is present."""

        return self.set_sync_mode("bypass")

    def require_external_sync(self) -> int:
        """Return a slave to XS20-gated playback mode."""

        return self.set_sync_mode("external")

    def sync(self, epoch: int = 1) -> int:
        """Emit one external SYNC pulse when this board is the master."""

        self._require_connected()
        if self._sync_mode == "bypass":
            raise SynchronizationError("sync() is disabled in bypass mode")
        if self._sync_role != "master":
            raise SynchronizationError("sync() requires sync_role='master'")
        response = self.rfctrl2_sync_epoch(int(epoch), wait_response=True)
        self._check_response(response, "SYNC_EPOCH")
        return 0

    def emit_trigger(self) -> int:
        """Emit one pulse on XS18 without starting local playback directly."""

        self._require_connected()
        response = self.rfctrl2_emit_trigger(wait_response=True)
        self._check_response(response, "EMIT_TRIGGER")
        self._capabilities = replace(
            self._capabilities,
            trigger_output_count=self._capabilities.trigger_output_count + 1,
        )
        return 0

    def rfctrl2_sync_epoch(self, epoch: int, seq: int | None = None, wait_response: bool = True,
                           retries: int = 0):
        sequence = self._next_sequence() if seq is None else int(seq)
        # SYNC_EPOCH is non-idempotent: the PL decoder does not deduplicate the
        # command by sequence number, so blindly re-sending it after a lost ACK
        # would emit a second XS20 pulse and start a second MTS/NCO alignment
        # epoch.  Never auto-retry here; SyncGroup verifies the real slave
        # event before deciding whether a re-send is actually required.
        return self._request(pack_rfctrl2_sync_epoch(epoch, sequence), RF2_OP_SYNC_EPOCH,
                             sequence, wait_response=wait_response, retries=retries)

    def rfctrl2_start_at(self, start_tick: int, seq: int | None = None, wait_response: bool = True):
        sequence = self._next_sequence() if seq is None else int(seq)
        return self._request(pack_rfctrl2_start_at(start_tick, sequence), RF2_OP_START_AT, sequence, wait_response=wait_response)

    def rfctrl2_set_sync_role(self, role: int, mode: int = RF2_SYNC_MODE_EXTERNAL,
                              seq: int | None = None, wait_response: bool = True):
        sequence = self._next_sequence() if seq is None else int(seq)
        response = self._request(
            pack_rfctrl2_set_sync_role(role, mode, sequence),
            RF2_OP_SET_SYNC_ROLE,
            sequence,
            wait_response=wait_response,
        )
        if wait_response:
            self._check_response(response, "SET_SYNC_ROLE")
        return response

    def rfctrl2_emit_trigger(self, seq: int | None = None, wait_response: bool = True):
        sequence = self._next_sequence() if seq is None else int(seq)
        response = self._request(
            pack_rfctrl2_emit_trigger(sequence),
            RF2_OP_EMIT_TRIGGER,
            sequence,
            wait_response=wait_response,
        )
        if wait_response:
            self._check_response(response, "EMIT_TRIGGER")
        return response

    def rfctrl2_network_get(self, seq: int | None = None, wait_response: bool = True, retries: int | None = None):
        sequence = self._next_sequence() if seq is None else int(seq)
        response = self._request(pack_rfctrl2_network_get(sequence), RF2_OP_NETWORK_GET, sequence, wait_response=wait_response, retries=retries)
        if wait_response:
            self._check_response(response, "NETWORK_GET")
            return parse_rfctrl2_network_response(response)
        return response

    def rfctrl2_network_apply(self, revision: int, ip: str, mac: str, subnet_mask: str = "255.255.255.0",
                              gateway: str = "0.0.0.0", port: int = 1234, seq: int | None = None,
                              wait_response: bool = True, retries: int | None = None):
        sequence = self._next_sequence() if seq is None else int(seq)
        response = self._request(pack_rfctrl2_network_apply(revision, ip, mac, subnet_mask, gateway, port, sequence),
                                 RF2_OP_NETWORK_APPLY, sequence, wait_response=wait_response, retries=retries)
        if wait_response:
            self._check_response(response, "NETWORK_APPLY")
            return parse_rfctrl2_network_response(response)
        return response

    def rfctrl2_network_restart(self, seq: int | None = None, wait_response: bool = True, retries: int | None = None):
        sequence = self._next_sequence() if seq is None else int(seq)
        response = self._request(pack_rfctrl2_network_restart(sequence), RF2_OP_NETWORK_RESTART, sequence, wait_response=wait_response, retries=retries)
        if wait_response:
            self._check_response(response, "NETWORK_RESTART")
            return parse_rfctrl2_network_response(response)
        return response

    def _map_channel(self, channel_type: str, channel: int) -> int:
        role = str(channel_type).lower()
        number = int(channel)
        if role in {"xy", "qc", "awg"}:
            if not 1 <= number <= 4:
                raise ParameterRangeError("xy channel must be in 1..4")
            return number
        if role == "z":
            if not 1 <= number <= 2:
                raise ParameterRangeError("z channel must be in 1..2")
            return 4 + number
        if role in {"ro", "ifout", "readout", "qr"}:
            if not 1 <= number <= 2:
                raise ParameterRangeError("ro/ifout channel must be in 1..2")
            return 6 + number
        if role in {"ri", "ifin"}:
            raise UnsupportedCapabilityError(f"{channel_type} channel {number}", "ADC/DAQ input")
        raise ParameterRangeError(f"unsupported channel type: {channel_type}")

    def _apply_pending(self, channel_mask: int = 0xFF):
        self._pending_revision = (self._pending_revision + 1) & 0xFFFFFFFF
        if not self.connected:
            if self.batch_mode:
                return {"revision": self._pending_revision, "applied_mask": channel_mask}
            raise ConnectionStateError("Dr47Device.connect() must be called before applying RFDC configuration")
        result = self.rfctrl2_rfdc_apply(
            self._pending_nco, self._pending_zone, self._pending_phase, self._pending_current,
            revision=self._pending_revision, channel_mask=channel_mask, retries=self.retries,
        )
        self._cache_rfdc_readback(result)
        return result

    def _cache_rfdc_readback(self, result: Mapping | None) -> None:
        if not isinstance(result, Mapping):
            return
        channels = []
        for item in result.get("channels", ()) or ():
            try:
                channels.append(RfdcChannelReadback(
                    channel=int(item["channel"]),
                    nco_hz=int(item.get("nco_hz", 0)),
                    nyquist_zone=int(item.get("nyquist_zone", 1)),
                    nco_phase_deg=float(item.get("nco_phase_deg", 0.0)),
                    dac_output_current_ma=float(item.get("dac_output_current_ma", 20.0)),
                    status=int(item.get("status", 0)),
                    nco_word=int(item.get("nco_word", 0)),
                    phase_word=int(item.get("phase_word", 0)),
                    vop_code=int(item.get("vop_code", 0)),
                ))
            except (KeyError, TypeError, ValueError):
                continue
        if channels or "config_valid_mask" in result:
            self._capabilities = replace(
                self._capabilities,
                config_valid_mask=int(result.get("config_valid_mask", self._capabilities.config_valid_mask)) & 0xFF,
                rfdc_readback=tuple(channels) if channels else self._capabilities.rfdc_readback,
                raw={**self._capabilities.raw, "rfdc_config": dict(result)},
            )

    def apply_rfdc_config(
        self,
        nco_ghz: Mapping | Sequence | None = None,
        nyquist_zone: Mapping | Sequence | None = None,
        phase_deg: Mapping | Sequence | None = None,
        output_current_ma: Mapping | Sequence | None = None,
        revision: int | None = None,
        channel_mask: int = 0xFF,
    ):
        """Apply and read back the eight-channel RFDC configuration.

        ``nco_ghz`` is the public unit.  Phase is in degrees and DAC output
        current remains in mA because those are the physical units exposed by
        the board.  The resulting RFCTRL2 fields are converted to integer Hz.
        """
        if nco_ghz is not None:
            for channel in range(1, 9):
                value = _mapping_channel_value(nco_ghz, channel, 0.0)
                self._pending_nco[channel] = ghz_to_hz(value)
        for target, source, default in (
            (self._pending_zone, nyquist_zone, 1),
            (self._pending_phase, phase_deg, 0.0),
            (self._pending_current, output_current_ma, 20.0),
        ):
            if source is None:
                continue
            for channel in range(1, 9):
                target[channel] = _mapping_channel_value(source, channel, default)
        if revision is not None:
            self._pending_revision = int(revision) & 0xFFFFFFFF
        return self._apply_pending(int(channel_mask))

    def set_xy_nco_frequency(self, channel: int, frequency_ghz: float) -> int:
        """Set an XY channel's RFDC NCO frequency in GHz."""

        physical = self._map_channel("xy", channel)
        value = ghz_to_hz(frequency_ghz)
        if not RFDC_NCO_MIN_HZ <= value <= RFDC_NCO_MAX_HZ:
            raise ParameterRangeError(
                f"XY NCO frequency must be in [{RFDC_NCO_MIN_GHZ}, {RFDC_NCO_MAX_GHZ}] GHz"
            )
        self._pending_nco[physical] = value
        # NCO sign and RFDC Nyquist zone are independent controls.  A negative
        # baseband frequency is valid in either zone; preserve the configured
        # zone instead of silently changing the requested RF image.
        if not self.batch_mode:
            self._apply_pending(1 << (physical - 1))
        return 0

    def set_gain(self, channel_type: Literal["xy", "z"], channel: int, gain: float = 1.0,
                 gain_type: Literal["norm", "dbm", "code", "volt"] = "norm") -> int:
        physical = self._map_channel(channel_type, channel)
        if gain_type != "norm":
            raise UnsupportedParameterError("set_gain", f"gain_type={gain_type!r}")
        value = float(gain)
        if not 0.0 <= value <= 1.0:
            raise ParameterRangeError("norm gain must be in [0, 1]")
        low, high = ((6.4, 32.0) if physical in (5, 6) else (2.25, 40.5))
        self._pending_current[physical] = low + value * (high - low)
        if not self.batch_mode:
            self._apply_pending(1 << (physical - 1))
        return 0

    def _set_channel_mask(self, channel_type: str, channel: int, on_off: str) -> int:
        physical = self._map_channel(channel_type, channel)
        state = str(on_off).lower()
        if state not in {"on", "off"}:
            raise ParameterRangeError("on_off must be 'on' or 'off'")
        bit = 1 << (physical - 1)
        if state == "on":
            self._channel_mask |= bit
        else:
            self._channel_mask &= ~bit
        self._mask_explicit = True
        return 0

    def set_qc_on_off(self, channel_type: str, channel: int, on_off: str = "on") -> int:
        return self._set_channel_mask(channel_type, channel, on_off)

    def set_qr_on_off(self, gen_type: str, channel: int, on_off: str = "on") -> int:
        if str(gen_type).lower() in {"ifin", "ri"}:
            raise UnsupportedCapabilityError("set_qr_on_off", "ADC/DAQ input")
        return self._set_channel_mask(gen_type, channel, on_off)

    def upload_waveforms(
        self,
        channel_waves: Mapping[int, np.ndarray | list],
        channel_sequences: Mapping[int, np.ndarray | list] | None = None,
        *,
        wave_formats: Mapping[int, str] | None = None,
        layout: str = DEFAULT_DDR_LAYOUT,
        base_addr: int = DDR_BASE,
        auto_start: bool = True,
        loop: bool = False,
        packet_pause_s: float = 1e-5,
        packet_burst: int = 8,
        channel_delays: Mapping[int, int] | None = None,
        instruction_repeats: int = 1,
    ) -> dict[str, Any]:
        """Upload one or more channels and queue WAVEINS0 playback commands."""
        if layout != DDR_LAYOUT_INTERLEAVED_512B:
            raise UnsupportedCapabilityError("upload_waveforms", "interleaved_512b DDR layout")
        if not channel_waves:
            raise ParameterRangeError("channel_waves must not be empty")
        normalized: dict[int, np.ndarray] = {}
        for logical, wave in channel_waves.items():
            channel = int(logical)
            if not 1 <= channel <= 8:
                raise ParameterRangeError("physical channel must be in 1..8")
            fmt = (wave_formats or {}).get(channel)
            if fmt is None:
                arr = np.asarray(wave)
                if arr.ndim == 2:
                    fmt = "iq_matrix"
                else:
                    fmt = _infer_wave_format(wave, channel)
            normalized[channel] = ezq_wave_to_interleaved_int16(wave, fmt)
        packet_pause = max(0.0, float(packet_pause_s))
        burst = max(1, int(packet_burst))
        packet_count = 0
        for packet in iter_interleaved_udp_waveform_packets(normalized, base_addr=base_addr):
            self.transport.send(packet)
            packet_count += 1
            # The PL UDP RX FIFO is intentionally small.  A host can enqueue
            # 10G packets faster than the DDR writer can drain AXI responses;
            # periodic pacing prevents silent packet loss on real hardware.
            if packet_pause and packet_count % burst == 0:
                time.sleep(packet_pause)
        commands: list[list[int]] = []
        delays = {} if channel_delays is None else {int(channel): int(delay) for channel, delay in channel_delays.items()}
        if any(channel not in normalized for channel in delays):
            raise ParameterRangeError("channel_delays contains a channel with no uploaded waveform")
        if any(delay < 0 for delay in delays.values()):
            raise ParameterRangeError("channel delay must be non-negative")
        wait_for_trigger = False
        loop_from_sequence = False
        if channel_sequences:
            for channel in sorted(normalized):
                sequence = channel_sequences.get(channel)
                if sequence is None:
                    continue
                fmt = (wave_formats or {}).get(channel, "packed_iq")
                translated, meta = sequence_to_play_commands(sequence, channel=channel, wave_format=fmt, base_addr=base_addr)
                commands.extend(translated[:-1])
                wait_for_trigger = wait_for_trigger or bool(meta["wait_for_trigger"])
                loop_from_sequence = loop_from_sequence or bool(meta["loop"])
        if not commands:
            for channel, wave in sorted(normalized.items()):
                # The web uploader emits a DELAY before every PLAY, including
                # a zero-delay row. Keep that available for packet parity.
                if channel_delays is not None:
                    commands.append([1, channel, delays.get(channel, 0), 0])
                commands.append([2, channel, waveform_length_bytes(wave), base_addr, PLAY_FLAG_INTERLEAVED])
        effective_loop = bool(loop or loop_from_sequence)
        commands.append([3, 0 if wait_for_trigger or not auto_start else 15, 0, 0, PLAY_FLAG_LOOP if effective_loop else 0])
        instruction_packet = pack_udp_instruction_packet(commands)
        repeats = max(1, int(instruction_repeats))
        for repeat_index in range(repeats):
            self.transport.send(instruction_packet)
            packet_count += 1
            if repeat_index + 1 < repeats:
                time.sleep(0.002)
        self._uploaded_channels.update(normalized)
        return {
            "packet_count": packet_count,
            "channels": tuple(sorted(normalized)),
            "bytes_per_channel": max(waveform_length_bytes(wave) for wave in normalized.values()),
            "wait_for_trigger": wait_for_trigger,
            "loop": effective_loop,
            "commands": commands,
            "instruction_repeats": repeats,
        }

    def arm(self, channel_mask: int | None = None, run_id: int | None = None) -> int:
        self._require_connected()
        mask = (self._channel_mask if self._mask_explicit else 0xFF) if channel_mask is None else int(channel_mask)
        if self._capabilities.config_valid_mask and mask & ~self._capabilities.config_valid_mask:
            raise DeviceNotReadyError("ARM", RF2_STATUS_RFDC_NOT_READY, "ARM mask is not configured by PL")
        if self._capabilities.capability_bits and not self._capabilities.has(RF2_CAP_PL_RFDC_CONFIG):
            raise UnsupportedCapabilityError("arm", "RF2_CAP_PL_RFDC_CONFIG", self._capabilities.capability_bits)
        token = self._run_id if run_id is None else int(run_id)
        arm_response = self.rfctrl2_arm(token, channel_mask=mask, wait_response=True)
        self._check_response(arm_response, "ARM")
        self._run_id = (token + 1) & 0xFFFFFFFF or 1
        self._channel_mask = mask
        self._capabilities = replace(
            self._capabilities,
            playback_state=PlaybackState.ARMED,
            playback_armed=True,
            playback_prepared=True,
            playback_running=False,
        )
        self._status = DeviceStatus(True, self.ip, self.port, PlaybackState.ARMED, self._capabilities, "ARM accepted")
        return 0

    def trigger(self) -> int:
        """Start local playback via RFCTRL2 TRIGGER.

        On a master, this is the atomic launch event: in the same DDR clock
        domain it starts local playback and asserts an XS18 pulse for the
        slave. On a slave, it starts local playback only and is still gated
        by external XS20 synchronization or the explicit bypass.
        """

        self._require_connected()
        trigger_response = self.rfctrl2_trigger(wait_response=True)
        self._check_response(trigger_response, "TRIGGER")
        self._capabilities = replace(
            self._capabilities,
            playback_state=PlaybackState.RUNNING,
            playback_armed=True,
            playback_prepared=True,
            playback_running=True,
        )
        self._status = DeviceStatus(True, self.ip, self.port, PlaybackState.RUNNING, self._capabilities, "TRIGGER accepted")
        return 0

    def abort_mute(self) -> int:
        self._require_connected()
        abort_response = self.rfctrl2_abort_mute(wait_response=True)
        self._check_response(abort_response, "ABORT_MUTE")
        self._capabilities = replace(
            self._capabilities,
            playback_state=PlaybackState.IDLE,
            playback_armed=False,
            playback_prepared=False,
            playback_running=False,
        )
        self._status = DeviceStatus(True, self.ip, self.port, PlaybackState.IDLE, self._capabilities, "ABORT_MUTE accepted")
        return 0

    def commit(self) -> int:
        if self.batch_mode:
            self._apply_pending(0xFF)
        return 0

    def close(self) -> None:
        with self._lock:
            self._closed = True
            self._connected = False
            if self._owns_transport and self._transport is not None:
                self._transport.close()
            self._status = DeviceStatus(False, self.ip, self.port, PlaybackState.IDLE, self._capabilities, "closed")

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, exc_type, exc, tb):
        self.close()
        return False


def _infer_wave_format(wave: Any, physical_channel: int) -> str:
    """Choose a useful default for ambiguous Python lists."""
    arr = np.asarray(wave)
    if arr.ndim == 2:
        return "iq_matrix"
    if isinstance(wave, (list, tuple)):
        values = [int(item) for item in arr.reshape(-1).tolist()]
        if values and all(-32768 <= item <= 32767 for item in values):
            return "z" if int(physical_channel) in (5, 6) else "interleaved_iq"
        return "packed_iq"
    return "packed_iq" if arr.dtype.itemsize >= 4 else "interleaved_iq"


def _mapping_channel_value(source: Mapping | Sequence, channel: int, default):
    if isinstance(source, Mapping):
        return source.get(channel, source.get(f"ch{channel}", default))
    values = list(source)
    if len(values) != 8:
        raise ParameterRangeError("configuration sequences must contain exactly eight values")
    return values[channel - 1]


def connect(*args: Any, **kwargs: Any) -> Dr47Device:
    """Construct and connect an :class:`Dr47Device` in one call."""
    device = Dr47Device(*args, **kwargs)
    device.connect()
    return device


__all__ = [
    "Dr47Device", "connect", "rfdc_nco_plan_for_target",
    "ghz_to_hz", "hz_to_ghz", "GHZ_TO_HZ",
    "RFDC_NCO_MIN_GHZ", "RFDC_NCO_MAX_GHZ",
]
