"""Public 47DR board object and direct RFCTRL2 control API.

The public driver API expresses RF frequencies in GHz.  RFCTRL2 still carries
signed integer Hz on the wire, so conversion is kept at this module boundary.
"""

from __future__ import annotations

import math
import threading
import time
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import replace
from typing import Any, Literal

import numpy as np

from .capabilities import DeviceCapabilities, DeviceStatus, PlaybackState, RfdcChannelReadback
from .capabilities import DiagnosticsSnapshot
from .errors import (
    ConnectionError,
    ConnectionStateError,
    DeviceBusyError,
    DeviceNotReadyError,
    DeviceStatusError,
    ParameterRangeError,
    ProtocolVersionError,
    ProtocolError,
    UnsupportedCapabilityError,
    UnsupportedParameterError,
    TransportTimeout,
)
from .protocol import *  # noqa: F401,F403 - protocol constants are part of the public API
from .protocol import _wave_uint, WAVE_DAC_FRAME_BYTES
from .protocol import (
    RF2_CAP_DAC_MTS,
    RF2_CAP_NCO_SYNC,
    RF2_CAP_PL_RFDC_CONFIG,
    RF2_STATUS_BAD_VERSION,
    RF2_STATUS_BUSY,
    RF2_STATUS_OK,
    RF2_STATUS_RFDC_NOT_READY,
    RF2_STATUS_UNSUPPORTED,
    RF2_STATUS_RANGE,
    pack_rfctrl2_hello,
    pack_rfctrl2_network_apply,
    pack_rfctrl2_network_get,
    pack_rfctrl2_network_restart,
    pack_rfctrl2_rfdc_apply,
    pack_rfctrl2_rfdc_get_config,
    pack_rfctrl2_status,
    parse_rfctrl2_network_response,
    parse_rfctrl2_rfdc_config_response,
    parse_rfctrl2_status_payload,
    parse_rfresp2_packet,
    pack_wave_begin, pack_wave_data, pack_wave_commit, pack_wave_play,
    pack_wave_pause, pack_wave_stop, pack_wave_abort, pack_wave_status,
    parse_wave_response, WAVE_OP_BEGIN, WAVE_OP_DATA, WAVE_OP_COMMIT,
    WAVE_OP_PLAY, WAVE_OP_PAUSE, WAVE_OP_STOP, WAVE_OP_ABORT, WAVE_OP_STATUS,
    WAVEFORM_STATE_NAMES, WAVEFORM_STATE_ID, WAVEFORM_STATE_UPLOAD,
    WAVEFORM_STATE_READY, WAVEFORM_STATE_PREFETCH, WAVEFORM_STATE_WAIT_TRIGGER,
    WAVEFORM_STATE_PLAYING, WAVEFORM_STATE_DRAINING, WAVEFORM_STATE_DONE,
    WAVEFORM_STATE_ERROR, WAVE_STATUS_OK,
)
from .transport import UdpTransport
from .waveforms import (
    DEFAULT_DDR_LAYOUT,
    DDR_LAYOUT_INTERLEAVED_512B,
    ezq_wave_to_interleaved_int16,
    pack_interleaved_512b_waveforms,
)


GHZ_TO_HZ = 1_000_000_000.0
RFDC_NCO_MIN_GHZ = RFDC_NCO_MIN_HZ / GHZ_TO_HZ
RFDC_NCO_MAX_GHZ = RFDC_NCO_MAX_HZ / GHZ_TO_HZ
_RFDC_IDLE_TIMEOUT_S = 5.0
_RFDC_IDLE_POLL_S = 0.05


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
        transport: object | None = None,
        expected_build_profile_id: int | None = RF2_BUILD_PROFILE_NORMAL,
        expected_trigger_path_version: int | None = RF2_TRIGGER_PATH_VERSION,
        expected_source_commit_id: int | None = None,
    ) -> None:
        self.ip = str(ip)
        self.port = int(port)
        self.timeout_s = float(timeout_s)
        self.udp_interface = str(udp_interface or "")
        self.udp_source_ip = str(udp_source_ip or "")
        self.retries = max(0, int(retries))
        self.batch_mode = bool(batch_mode)
        self.expected_build_profile_id = None if expected_build_profile_id is None else int(expected_build_profile_id)
        self.expected_trigger_path_version = None if expected_trigger_path_version is None else int(expected_trigger_path_version)
        self.expected_source_commit_id = None if expected_source_commit_id is None else int(expected_source_commit_id) & 0xFFFFFFFF
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
            state = PlaybackState.PLAYING
        elif decoded.get("prepared"):
            state = PlaybackState.WAIT_TRIGGER
        elif decoded.get("armed"):
            state = PlaybackState.READY
        else:
            state = PlaybackState.IDLE
        self._capabilities = DeviceCapabilities(
            device_uid=str(decoded.get("device_uid", self._capabilities.device_uid)),
            protocol_version=int(response.get("version", RFCTRL2_VERSION)),
            build_profile_id=int(decoded.get("build_profile_id", self._capabilities.build_profile_id)),
            build_profile=str(decoded.get("build_profile", self._capabilities.build_profile)),
            source_commit_id=int(decoded.get("source_commit_id", self._capabilities.source_commit_id)) & 0xFFFFFFFF,
            trigger_path_version=int(decoded.get("trigger_path_version", self._capabilities.trigger_path_version)) & 0xFFFFFFFF,
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
            trigger_input_count=int(decoded.get("trigger_input_count", 0)) & 0xFFFFFFFF,
            trigger_accepted_count=int(decoded.get("trigger_accepted_count", 0)) & 0xFFFFFFFF,
            trigger_output_count=int(decoded.get("trigger_output_count", 0)) & 0xFFFFFFFF,
            ext_trigger_phase_slot=int(decoded.get("ext_trigger_phase_slot", 0)) & 0x7,
            ext_trigger_phase_valid=bool(decoded.get("ext_trigger_phase_valid", False)),
            ext_trigger_phase_overflow=bool(decoded.get("ext_trigger_phase_overflow", False)),
            ext_trigger_phase_metastable=bool(decoded.get("ext_trigger_phase_metastable", False)),
            ext_trigger_tap_index=int(decoded.get("ext_trigger_tap_index", 0)) & 0xFF,
            ext_trigger_phase_ps_x10=int(decoded.get("ext_trigger_phase_ps_x10", 0)) & 0xFFFF,
            playback_admitted_count=int(decoded.get("playback_admitted_count", 0)) & 0xFFFFFFFF,
            playback_skipped_count=int(decoded.get("playback_skipped_count", 0)) & 0xFFFFFFFF,
            config_valid_mask=int(decoded.get("config_valid_mask", 0)) & 0xFF,
            playback_state=state,
            playback_armed=bool(decoded.get("armed")),
            playback_prepared=bool(decoded.get("prepared")),
            playback_running=bool(decoded.get("running")),
            raw=dict(decoded),
        )
        self._status = DeviceStatus(self._connected, self.ip, self.port, state, self._capabilities, "RFCTRL2 online", dict(decoded))
        return self._capabilities

    def _validate_identity(self, response: Mapping, operation: str) -> None:
        """Reject a v3 bitstream built for a different hardware contract.

        Test transports and very old read-only replies may omit the payload;
        a real v3 HELLO/STATUS always carries the identity extension.  Once an
        identity is present it is never silently ignored.
        """
        payload = bytes(response.get("payload", b""))
        if len(payload) < 112:
            return
        decoded = parse_rfctrl2_status_payload(response)
        profile = int(decoded.get("build_profile_id", 0))
        trigger_path = int(decoded.get("trigger_path_version", 0))
        source_commit = int(decoded.get("source_commit_id", 0))
        if self.expected_build_profile_id is not None and profile != self.expected_build_profile_id:
            raise ProtocolVersionError(
                f"RFCTRL2 {operation} build profile {profile} is incompatible with expected "
                f"{self.expected_build_profile_id}"
            )
        if self.expected_trigger_path_version is not None and trigger_path != self.expected_trigger_path_version:
            raise ProtocolVersionError(
                f"RFCTRL2 {operation} trigger path version {trigger_path} is incompatible with expected "
                f"{self.expected_trigger_path_version}"
            )
        if self.expected_source_commit_id is not None and source_commit != self.expected_source_commit_id:
            raise ProtocolVersionError(
                f"RFCTRL2 {operation} source commit 0x{source_commit:08X} does not match expected "
                f"0x{self.expected_source_commit_id:08X}"
            )

    def connect(self) -> int:
        with self._lock:
            if self._closed:
                raise ConnectionStateError("cannot connect a closed Dr47Device")
            try:
                # A board can transiently miss one RFRESP2 while its PL UDP
                # response path is recovering from a prior RFDC alignment.
                # Retrying only the current packet is insufficient when that
                # lost reply was HELLO: the next STATUS must be paired with a
                # fresh, confirmed handshake.  Retry the *whole* HELLO then
                # STATUS transaction once, with new sequence numbers.  This
                # path is safe because HELLO and STATUS are read-only.
                for handshake_attempt in range(2):
                    try:
                        hello_seq = self._next_sequence()
                        hello = self._request(
                            pack_rfctrl2_hello(hello_seq),
                            RF2_OP_HELLO,
                            hello_seq,
                            retries=self.retries,
                        )
                        self._check_response(hello, "HELLO")
                        self._validate_identity(hello, "HELLO")
                        self._connected = True
                        self._update_from_status(hello)
                        # STATUS is authoritative when a board returns a
                        # short HELLO.
                        status_seq = self._next_sequence()
                        status = self._request(
                            pack_rfctrl2_status(status_seq),
                            RF2_OP_STATUS,
                            status_seq,
                            retries=self.retries,
                        )
                        self._check_response(status, "STATUS")
                        self._validate_identity(status, "STATUS")
                        self._update_from_status(status)
                        return 0
                    except TransportTimeout:
                        self._connected = False
                        if handshake_attempt == 0:
                            time.sleep(0.05)
                            continue
                        raise
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

    def read_diagnostics(self) -> DiagnosticsSnapshot:
        """Read the hardware-latched RFCTRL2 diagnostic snapshot."""
        self._require_connected()
        seq = self._next_sequence()
        response = self._request(pack_rfctrl2_diag_snapshot(seq), RF2_OP_DIAG_SNAPSHOT, seq, retries=self.retries)
        self._check_response(response, "DIAG_SNAPSHOT")
        decoded = parse_rfctrl2_diagnostics_payload(response)
        return DiagnosticsSnapshot(**{k: v for k, v in decoded.items() if k in DiagnosticsSnapshot.__dataclass_fields__})

    def clear_diagnostics(self, events: int = 0xFFFFFFFF, counters: bool = True):
        """Clear sticky diagnostic events (W1C) and optionally counters."""
        self._require_connected()
        seq = self._next_sequence()
        response = self._request(pack_rfctrl2_diag_control(events, counters, seq), RF2_OP_DIAG_CONTROL, seq, retries=0)
        self._check_response(response, "DIAG_CONTROL")
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

    def _wave_request(self, packet: bytes, opcode: int, seq: int, *, wait_response: bool = True):
        # The transport owns the retry deadline and immutable request identity.
        # Do not fall back to ad-hoc send/receive paths that lose either.
        return self.transport.request_wave(packet, seq=seq, opcode=opcode,
                                           retries=self.retries, wait_response=wait_response)

    @staticmethod
    def _check_wave_response(response: Mapping, operation: str) -> Mapping:
        if "status" not in response:
            raise ProtocolError(f"{operation} response has no status")
        status = int(response["status"])
        if status != WAVE_STATUS_OK:
            raise DeviceStatusError(operation, status, str(response.get("error_code", "")))
        return response

    def waveform_status(self, session: int = 0):
        self._require_connected()
        seq = self._next_sequence()
        return self._wave_request(pack_wave_status(session=session, seq=seq), WAVE_OP_STATUS, seq)

    def begin_waveform(self, *, session: int, total_bytes: int, channel_mask: int,
                       total_beats: int, loop_count: int = 1, layout: int = WAVE_LAYOUT_INTERLEAVED_512B):
        self._require_connected()
        seq = self._next_sequence()
        return self._wave_request(pack_wave_begin(session=session, total_bytes=total_bytes,
            channel_mask=channel_mask, total_beats=total_beats, loop_count=loop_count,
            layout=layout, seq=seq), WAVE_OP_BEGIN, seq)

    def data_waveform(self, *, session: int, packet_seq: int, byte_offset: int,
                      payload: bytes):
        self._require_connected()
        seq = self._next_sequence()
        return self._wave_request(pack_wave_data(session=session, packet_seq=packet_seq,
            byte_offset=byte_offset, payload=payload, seq=seq), WAVE_OP_DATA, seq)

    def commit_waveform(self, *, session: int):
        self._require_connected()
        seq = self._next_sequence()
        return self._wave_request(pack_wave_commit(session=session, seq=seq), WAVE_OP_COMMIT, seq)

    def play(self, *, session: int = 0):
        self._require_connected()
        seq = self._next_sequence()
        return self._wave_request(pack_wave_play(session=session, seq=seq), WAVE_OP_PLAY, seq)

    def pause(self, *, session: int = 0):
        self._require_connected()
        seq = self._next_sequence()
        return self._wave_request(pack_wave_pause(session=session, seq=seq), WAVE_OP_PAUSE, seq)

    def stop(self, *, session: int = 0):
        self._require_connected()
        seq = self._next_sequence()
        return self._wave_request(pack_wave_stop(session=session, seq=seq), WAVE_OP_STOP, seq)

    def abort(self, *, session: int = 0):
        self._require_connected()
        seq = self._next_sequence()
        return self._wave_request(pack_wave_abort(session=session, seq=seq), WAVE_OP_ABORT, seq)

    def _tdc_register(self, address: int, *, write: bool = False, data: int = 0) -> int:
        self._require_connected()
        sequence = self._next_sequence()
        packet = pack_rfctrl2_tdc_register(address, write=write, data=data, seq=sequence)
        # Some writes clear counters or commit calibration, so never replay a timed-out write.
        response = self._request(packet, RF2_OP_TDC_REG, sequence, retries=0 if write else None)
        self._check_response(response, "TDC_REG")
        return parse_rfctrl2_tdc_register_response(response, address)

    def read_tdc_register(self, address: int) -> int:
        """Read a 32-bit TDC register at its aligned byte address."""
        return self._tdc_register(address)

    def write_tdc_register(self, address: int, data: int) -> int:
        """Write a TDC register and return its controller acknowledgement value."""
        return self._tdc_register(address, write=True, data=data)

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
        try:
            result = self.rfctrl2_rfdc_apply(
                self._pending_nco, self._pending_zone, self._pending_phase, self._pending_current,
                revision=self._pending_revision, channel_mask=channel_mask, retries=self.retries,
            )
        except DeviceStatusError as exc:
            # RFDC_APPLY is intentionally rejected while playback is armed or
            # running.  The PL also emits a force-mute pulse for this status,
            # but that pulse crosses clock domains asynchronously; explicitly
            # abort and wait for a confirmed IDLE state before retrying once.
            # This makes repeated commits deterministic without retrying
            # unrelated protocol, range, AXI, or readiness failures.
            if exc.operation != "RFDC_APPLY" or exc.status != RF2_STATUS_UNSAFE_STATE:
                raise
            self.abort()
            self._wait_for_playback_idle()
            result = self.rfctrl2_rfdc_apply(
                self._pending_nco, self._pending_zone, self._pending_phase, self._pending_current,
                revision=self._pending_revision, channel_mask=channel_mask, retries=self.retries,
            )
        self._cache_rfdc_readback(result)
        return result

    def _wait_for_playback_idle(self, timeout_s: float = _RFDC_IDLE_TIMEOUT_S) -> None:
        """Wait until the board confirms that RFDC changes are safe to apply."""

        deadline = time.monotonic() + float(timeout_s)
        last_state = self._status.state.value
        while time.monotonic() < deadline:
            status = self.status(refresh=True)
            last_state = status.state.value
            if status.state is PlaybackState.IDLE:
                return
            time.sleep(_RFDC_IDLE_POLL_S)
        raise TimeoutError(
            f"playback did not become IDLE before RFDC_APPLY retry (last state={last_state})"
        )

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

    def set_xy_target_frequency(
        self,
        channel: int,
        target_rf_ghz: float,
        dac_fs_ghz: float = 6.4,
    ) -> dict[str, float | int | str]:
        """Set an XY channel for an analog RF target, including Nyquist zone.

        The RFDC NCO itself is limited to ``[-3.2, 3.2]`` GHz for the current
        6.4 GS/s DAC.  Targets above 3.2 GHz are represented by the second
        Nyquist image, for example 4.0 GHz becomes NCO=-2.4 GHz with zone 2.
        The returned plan is useful for logging and measurement records.
        """

        plan = rfdc_nco_plan_for_target(float(target_rf_ghz), float(dac_fs_ghz))
        physical = self._map_channel("xy", channel)
        self._pending_nco[physical] = ghz_to_hz(float(plan["nco_ghz"]))
        self._pending_zone[physical] = int(plan["nyquist_zone"])
        if not self.batch_mode:
            self._apply_pending(1 << (physical - 1))
        return plan

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
        channel_sequences=None,
        *,
        wave_formats: Mapping[int, str] | None = None,
        channel_mask: int | None = None,
        loop_count: int = 1,
        progress_callback: Callable[[int, int], object] | None = None,
        **_kwargs: Any,
    ) -> dict[str, Any]:
        """Upload one uniform eight-lane image and COMMIT it.

        The new wire contract has no instruction stream: channel data is packed
        once in interleaved 512-bit beats, then BEGIN/DATA/COMMIT creates the
        descriptor and starts hardware prefetch automatically.
        """
        if not channel_waves:
            raise ParameterRangeError("channel_waves must not be empty")
        if channel_sequences:
            raise UnsupportedParameterError("channel_sequences", "instruction playback was removed")
        normalized: dict[int, np.ndarray] = {}
        for channel, wave in channel_waves.items():
            physical = int(channel)
            if not 1 <= physical <= 8:
                raise ParameterRangeError("physical channel must be in 1..8")
            fmt = (wave_formats or {}).get(physical) or _infer_wave_format(wave, physical)
            normalized[physical] = ezq_wave_to_interleaved_int16(wave, fmt)
        mask = _wave_uint(channel_mask if channel_mask is not None else
                          sum(1 << (ch - 1) for ch in normalized), 8, "channel_mask", nonzero=True)
        normalized = {ch: wave if mask & (1 << (ch - 1)) else np.zeros_like(wave)
                      for ch, wave in normalized.items()}
        image, sample_count = pack_interleaved_512b_waveforms(normalized)
        if not image:
            raise ParameterRangeError("waveform image must contain at least one beat")
        mask = int(channel_mask) if channel_mask is not None else sum(1 << (ch - 1) for ch in normalized)
        session = self._run_id
        self._run_id = (session + 1) & 0xFFFFFFFF or 1
        packet_bytes = 1024
        total_packets = (len(image) + packet_bytes - 1) // packet_bytes
        if progress_callback:
            progress_callback(0, total_packets)
        self._check_wave_response(self.begin_waveform(
            session=session, total_bytes=len(image), channel_mask=mask,
            total_beats=len(image) // WAVE_DAC_FRAME_BYTES,
            loop_count=loop_count), "BEGIN")
        for packet_seq, offset in enumerate(range(0, len(image), packet_bytes)):
            self._check_wave_response(self.data_waveform(
                session=session, packet_seq=packet_seq, byte_offset=offset,
                payload=image[offset:offset + packet_bytes]), "DATA")
            if progress_callback:
                progress_callback(packet_seq + 1, total_packets)
        committed = self._check_wave_response(self.commit_waveform(session=session), "COMMIT")
        return {
            "session": session, "channels": tuple(sorted(normalized)),
            "channel_mask": mask, "bytes": len(image), "bytes_per_channel": sample_count * 2,
            "total_beats": len(image) // WAVE_DAC_FRAME_BYTES,
            "loop_count": int(loop_count), "packet_count": total_packets,
            "state": committed.get("state"), "descriptor": committed.get("descriptor"),
        }

    def upload_interleaved_chunks(
        self,
        chunks: Iterable[tuple[int, bytes]],
        *,
        total_bytes: int,
        total_beats: int,
        channel_mask: int,
        loop_count: int = 1,
        session: int | None = None,
        packet_bytes: int = 1024,
        packet_pause_s: float = 0.0,
        progress_callback: Callable[[int, int], object] | None = None,
    ) -> dict[str, Any]:
        """Stream an already-interleaved record through BEGIN/DATA/COMMIT.

        ``chunks`` contains ``(byte_offset, payload)`` pairs in ascending,
        contiguous order.  Large producer chunks are fragmented into protocol
        DATA packets, so callers can generate/cache max-length records without
        materialising the complete DDR image in host memory.  The descriptor
        uses the same per-channel DAC-beat unit as :meth:`upload_waveforms`:
        one descriptor beat is four 64-byte DDR beats, or 256 bytes total.
        """
        self._require_connected()
        total_bytes = _wave_uint(total_bytes, 64, "total_bytes", nonzero=True)
        total_beats = _wave_uint(total_beats, 32, "total_beats", nonzero=True)
        channel_mask = _wave_uint(channel_mask, 8, "channel_mask", nonzero=True)
        loop_count = _wave_uint(loop_count, 32, "loop_count", nonzero=True)
        if total_bytes != total_beats * WAVE_DAC_FRAME_BYTES:
            raise ParameterRangeError("total_bytes must equal total_beats * 8 * 32")
        packet_bytes = int(packet_bytes)
        if packet_bytes < 32 or packet_bytes % 32:
            raise ParameterRangeError("packet_bytes must be a positive 32-byte multiple")
        max_data = ((UDP_MAX_PAYLOAD_BYTES - WAVE_CTRL_HEADER_BYTES - WAVE_DATA_HEADER_BYTES) // 32) * 32
        if packet_bytes > max_data:
            raise ParameterRangeError(f"packet_bytes must not exceed {max_data}")
        if session is None:
            session = self._run_id
            self._run_id = (session + 1) & 0xFFFFFFFF or 1
        else:
            session = _wave_uint(session, 32, "session", nonzero=True)
        total_packets = (total_bytes + packet_bytes - 1) // packet_bytes
        if progress_callback:
            progress_callback(0, total_packets)
        begin = self._check_wave_response(self.begin_waveform(
            session=session, total_bytes=total_bytes, channel_mask=channel_mask,
            total_beats=total_beats, loop_count=loop_count), "BEGIN")
        expected_offset = 0
        packet_seq = 0
        sent_packets = 0
        for offset, payload in chunks:
            offset = _wave_uint(offset, 64, "chunk byte offset")
            raw = bytes(payload)
            if offset != expected_offset:
                raise ParameterRangeError(
                    f"interleaved chunks must be contiguous: expected offset {expected_offset}, got {offset}"
                )
            if not raw or len(raw) % 32 or offset + len(raw) > total_bytes:
                raise ParameterRangeError("interleaved chunks must be non-empty, 32-byte aligned, and fit total_bytes")
            for start in range(0, len(raw), packet_bytes):
                piece = raw[start:start + packet_bytes]
                self._check_wave_response(self.data_waveform(
                    session=session, packet_seq=packet_seq,
                    byte_offset=offset + start, payload=piece), "DATA")
                packet_seq += 1
                sent_packets += 1
                if progress_callback:
                    progress_callback(sent_packets, total_packets)
                if packet_pause_s > 0.0:
                    time.sleep(float(packet_pause_s))
            expected_offset += len(raw)
        if expected_offset != total_bytes:
            raise ParameterRangeError(
                f"interleaved chunks contain {expected_offset} bytes, expected {total_bytes}"
            )
        committed = self._check_wave_response(self.commit_waveform(session=session), "COMMIT")
        return {
            "session": session,
            "channel_mask": channel_mask,
            "bytes": total_bytes,
            "total_beats": total_beats,
            "loop_count": loop_count,
            "packet_count": sent_packets,
            "state": committed.get("state"),
            "descriptor": committed.get("descriptor"),
        }

    def upload_and_commit(self, image: bytes, *, session: int, channel_mask: int,
                          total_beats: int, loop_count: int = 1, packet_bytes: int = 1024):
        raw = bytes(image)
        self.begin_waveform(session=session, total_bytes=len(raw), channel_mask=channel_mask,
                            total_beats=total_beats, loop_count=loop_count)
        for packet_seq, offset in enumerate(range(0, len(raw), int(packet_bytes))):
            chunk = raw[offset:offset + int(packet_bytes)]
            self.data_waveform(session=session, packet_seq=packet_seq, byte_offset=offset, payload=chunk)
        return self.commit_waveform(session=session)

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
