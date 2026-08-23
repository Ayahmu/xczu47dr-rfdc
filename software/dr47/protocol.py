"""Wire-format helpers for the XCZU47DR RFCTRL2 playback protocol.

All integer fields in the UDP control protocols are little endian.  The
helpers in this module are deliberately free of socket or device state so
they can be used for packet-level tests and offline tooling.
"""

from __future__ import annotations

import socket
import struct
from typing import Iterable, Mapping, Sequence

from .errors import ParameterRangeError, ProtocolError, ProtocolVersionError

UDP_RFCTRL2_MAGIC = 0x00324C5254434652
UDP_RFRESP2_MAGIC = 0x0032505345524652
# Readable aliases used by packet-analysis scripts.
RFCTRL2_MAGIC = UDP_RFCTRL2_MAGIC
RFRESP2_MAGIC = UDP_RFRESP2_MAGIC
RFCTRL2_VERSION = 2

RF2_OP_HELLO = 0x01
RF2_OP_STATUS = 0x02
RF2_OP_RFDC_APPLY = 0x03
RF2_OP_SET_NCO = RF2_OP_RFDC_APPLY
RF2_OP_UPLOAD_BEGIN = 0x04
RF2_OP_UPLOAD_COMMIT = 0x05
RF2_OP_ARM = 0x06
RF2_OP_SYNC_EPOCH = 0x07
RF2_OP_START_AT = 0x08
RF2_OP_TRIGGER = 0x09
RF2_OP_ABORT_MUTE = 0x0A
RF2_OP_RFDC_GET_CONFIG = 0x0B
RF2_OP_NETWORK_GET = 0x0C
RF2_OP_NETWORK_APPLY = 0x0D
RF2_OP_NETWORK_RESTART = 0x0E
RF2_OP_SET_SYNC_ROLE = 0x0F
RF2_OP_EMIT_TRIGGER = 0x10

RF2_CAP_PL_RFDC_CONFIG = 0x00010000
RF2_CAP_RFDC_GET_CONFIG = 0x00020000
RF2_CAP_NETWORK_CONFIG = 0x00040000
RF2_CAP_DAC_MTS = 0x00080000
RF2_CAP_NCO_SYNC = 0x00100000
RF2_CAP_SYNC_IO = 0x00200000
RF2_CAP_TRIGGER_IO = 0x00400000

RF2_BUILD_PROFILE_UNKNOWN = 0
RF2_BUILD_PROFILE_NORMAL = 1
RF2_BUILD_PROFILE_BANDWIDTH = 3
RF2_BUILD_PROFILE_NAMES = {
    RF2_BUILD_PROFILE_NORMAL: "custom_xczu47dr",
    RF2_BUILD_PROFILE_BANDWIDTH: "custom_xczu47dr_bw",
}

RF2_STATUS_RFDC_READY = 0x00000001
RF2_STATUS_RFDC_BUSY = 0x00000002
RF2_STATUS_ARMED = 0x00000004
RF2_STATUS_RUNNING = 0x00000008
RF2_STATUS_PREPARED = 0x00000010
RF2_STATUS_DAC_MTS_READY = 0x00000020
RF2_STATUS_DAC_MTS_FAILED = 0x00000040
RF2_STATUS_NCO_SYNC_READY = 0x00000080
RF2_STATUS_DAC_MTS_REQUIRED = 0x00000100
RF2_NET_STATUS_HMC_DONE = 0x00000020
RF2_NET_STATUS_SYNC_DONE = 0x00000040

RF2_STATUS_OK = 0x0000
RF2_STATUS_BAD_VERSION = 0x0001
RF2_STATUS_UNSUPPORTED = 0x0002
RF2_STATUS_BAD_REQUEST = 0x0003
RF2_STATUS_BUSY = 0x0004
RF2_STATUS_RFDC_NOT_READY = 0x0005
RF2_STATUS_UNSAFE_STATE = 0x0006
RF2_STATUS_RANGE = 0x0007
RF2_STATUS_AXI_ERROR = 0x0008
RF2_STATUS_AXI_TIMEOUT = 0x0009
RF2_STATUS_READBACK = 0x000A
RF2_STATUS_PARTIAL = 0x000B

RF2_SYNC_ROLE_SLAVE = 0
RF2_SYNC_ROLE_MASTER = 1
RF2_SYNC_MODE_EXTERNAL = 0
RF2_SYNC_MODE_BYPASS = 1
# Wire-compatible spelling retained for early callers. New applications must
# use RF2_SYNC_MODE_BYPASS and the public ``bypass`` mode string.
RF2_SYNC_MODE_SELF_TEST = RF2_SYNC_MODE_BYPASS
RF2_SYNC_STATUS_SEEN = 0x00000001
RF2_SYNC_STATUS_READY = 0x00000002
RF2_SYNC_STATUS_BYPASS = 0x00000004
RF2_SYNC_STATUS_SELF_TEST = RF2_SYNC_STATUS_BYPASS
RF2_SYNC_STATUS_ROLE_MASTER = 0x00000008
RF2_SYNC_STATUS_INPUT_HIGH = 0x00000010
RF2_SYNC_STATUS_OUTPUT_HIGH = 0x00000020

RFDC_APPLY_CHANNELS = 8
RFDC_APPLY_REQUEST_HEADER_BYTES = 8
RFDC_APPLY_REQUEST_ENTRY_BYTES = 24
RFDC_APPLY_RESPONSE_HEADER_BYTES = 32
RFDC_APPLY_RESPONSE_ENTRY_BYTES = 40
RFDC_NCO_MIN_HZ = -3_200_000_000
RFDC_NCO_MAX_HZ = 3_200_000_000
NETWORK_RESPONSE_BYTES = 64
NETWORK_EXT_RESPONSE_BYTES = 80

UDP_WAVE_DDR_MAGIC = 0x5741564544445230
UDP_WAVE_BULK_MAGIC = 0x5741564553545230
UDP_WAVE_INSTR_MAGIC = 0x57415645494E5330
WAVEDDR0_MAGIC = UDP_WAVE_DDR_MAGIC
WAVESTR0_MAGIC = UDP_WAVE_BULK_MAGIC
WAVEINS0_MAGIC = UDP_WAVE_INSTR_MAGIC
BEAT_BYTES = 32
DDR_BASE = 0
DDR_TILE_BYTES = 4096
DDR_TILE_CHANNELS = 8
DDR_SUPERBLOCK_BYTES = DDR_TILE_BYTES * DDR_TILE_CHANNELS
DDR_INTERLEAVED_LANE_BYTES = 8
DDR_INTERLEAVED_BEAT_BYTES = DDR_INTERLEAVED_LANE_BYTES * DDR_TILE_CHANNELS
DDR_INTERLEAVED_CHANNELS = DDR_TILE_CHANNELS
DDR_PHYS_BYTES = 8 * 1024 * 1024 * 1024
DDR_RESERVED_TOP_BYTES = 1 * 1024 * 1024
DDR_USABLE_WAVEFORM_BYTES = DDR_PHYS_BYTES - DDR_RESERVED_TOP_BYTES
DDR_MAX_BYTES_PER_CHANNEL = (DDR_USABLE_WAVEFORM_BYTES // DDR_INTERLEAVED_CHANNELS) & ~(BEAT_BYTES - 1)
DDR_MAX_INTERLEAVED_BYTES = DDR_MAX_BYTES_PER_CHANNEL * DDR_INTERLEAVED_CHANNELS
FIXED_DATA_BYTES = DDR_TILE_BYTES
PLAY_FLAG_LOOP = 0x1
PLAY_FLAG_TILED = 0x2
PLAY_FLAG_INTERLEAVED = 0x4
UDP_STANDARD_MTU_BYTES = 1500
UDP_IPV4_HEADER_BYTES = 20
UDP_HEADER_BYTES = 8
UDP_MAX_PAYLOAD_BYTES = UDP_STANDARD_MTU_BYTES - UDP_IPV4_HEADER_BYTES - UDP_HEADER_BYTES
UDP_BULK_HEADER_BYTES = 24
UDP_BULK_MAX_BEATS = (UDP_MAX_PAYLOAD_BYTES - UDP_BULK_HEADER_BYTES) // DDR_INTERLEAVED_BEAT_BYTES
UDP_BULK_SAFE_MAX_BEATS = 4

CHANNEL_ROLES = {
    1: "xy", 2: "xy", 3: "xy", 4: "xy",
    5: "z", 6: "z", 7: "readout", 8: "readout",
}


def validate_udp_bulk_beats(beats_per_datagram: int) -> int:
    beats = int(beats_per_datagram)
    if beats <= 0:
        raise ParameterRangeError("beats_per_datagram must be positive")
    if beats > UDP_BULK_SAFE_MAX_BEATS:
        raise ParameterRangeError(
            f"beats_per_datagram={beats} exceeds the PL UDP bulk parser limit of {UDP_BULK_SAFE_MAX_BEATS}"
        )
    payload_bytes = UDP_BULK_HEADER_BYTES + beats * DDR_INTERLEAVED_BEAT_BYTES
    if payload_bytes > UDP_MAX_PAYLOAD_BYTES:
        raise ParameterRangeError(
            f"beats_per_datagram={beats} produces a {payload_bytes}-byte UDP payload; maximum is {UDP_MAX_PAYLOAD_BYTES}"
        )
    return beats


def pack_rfctrl2_packet(opcode: int, payload: bytes = b"", seq: int = 1, flags: int = 0) -> bytes:
    raw = bytes(payload)
    padded = raw + b"\x00" * ((-len(raw)) % 8)
    hdr0 = ((int(opcode) & 0xFFFFFFFF) << 32) | ((int(flags) & 0xFFFF) << 16) | RFCTRL2_VERSION
    hdr1 = ((len(raw) & 0xFFFFFFFF) << 32) | (int(seq) & 0xFFFFFFFF)
    return struct.pack("<QQQ", UDP_RFCTRL2_MAGIC, hdr0, hdr1) + padded


def pack_rfctrl2_hello(seq: int = 1) -> bytes:
    return pack_rfctrl2_packet(RF2_OP_HELLO, seq=seq)


def pack_rfctrl2_status(seq: int = 1) -> bytes:
    return pack_rfctrl2_packet(RF2_OP_STATUS, seq=seq)


def pack_rfctrl2_arm(run_id: int, channel_mask: int = 0xFF, seq: int = 1) -> bytes:
    return pack_rfctrl2_packet(RF2_OP_ARM, struct.pack("<II", int(run_id) & 0xFFFFFFFF, int(channel_mask) & 0xFF), seq=seq)


def pack_rfctrl2_trigger(seq: int = 1) -> bytes:
    return pack_rfctrl2_packet(RF2_OP_TRIGGER, seq=seq)


def pack_rfctrl2_abort_mute(seq: int = 1) -> bytes:
    return pack_rfctrl2_packet(RF2_OP_ABORT_MUTE, seq=seq)


def pack_rfctrl2_sync_epoch(epoch: int, seq: int = 1) -> bytes:
    return pack_rfctrl2_packet(RF2_OP_SYNC_EPOCH, struct.pack("<Q", int(epoch) & 0xFFFFFFFFFFFFFFFF), seq=seq)


def pack_rfctrl2_start_at(start_tick: int, seq: int = 1) -> bytes:
    return pack_rfctrl2_packet(RF2_OP_START_AT, struct.pack("<Q", int(start_tick) & 0xFFFFFFFFFFFFFFFF), seq=seq)


def pack_rfctrl2_set_sync_role(role: int, mode: int = RF2_SYNC_MODE_EXTERNAL, seq: int = 1) -> bytes:
    role_value = int(role)
    mode_value = int(mode)
    if role_value not in {RF2_SYNC_ROLE_SLAVE, RF2_SYNC_ROLE_MASTER}:
        raise ParameterRangeError("sync role must be 0 (slave) or 1 (master)")
    if mode_value not in {RF2_SYNC_MODE_EXTERNAL, RF2_SYNC_MODE_SELF_TEST}:
        raise ParameterRangeError("sync mode must be 0 (external) or 1 (bypass)")
    return pack_rfctrl2_packet(
        RF2_OP_SET_SYNC_ROLE,
        struct.pack("<II", role_value, mode_value),
        seq=seq,
    )


def pack_rfctrl2_emit_trigger(seq: int = 1) -> bytes:
    return pack_rfctrl2_packet(RF2_OP_EMIT_TRIGGER, seq=seq)


def _channel_value(mapping: Mapping | Sequence, channel: int, default):
    if isinstance(mapping, Mapping):
        return mapping.get(channel, mapping.get(f"ch{channel}", default))
    values = list(mapping)
    if len(values) != RFDC_APPLY_CHANNELS:
        raise ParameterRangeError("RFDC configuration requires exactly eight channel values")
    return values[channel - 1]


def normalize_rfdc_phase_mdeg(phase_deg: float) -> int:
    phase = ((float(phase_deg) + 180.0) % 360.0) - 180.0
    return int(round(phase * 1000.0))


def pack_rfctrl2_rfdc_apply(
    per_channel_nco_hz,
    per_channel_nyquist_zone,
    per_channel_phase_deg,
    per_channel_output_current_ma,
    revision: int,
    channel_mask: int = 0xFF,
    seq: int = 1,
) -> bytes:
    mask = int(channel_mask)
    if not 1 <= mask <= 0xFF:
        raise ParameterRangeError(f"RFDC channel_mask must select CH1..CH8, got 0x{mask:X}")
    payload = bytearray(struct.pack("<II", int(revision) & 0xFFFFFFFF, mask))
    for channel in range(1, RFDC_APPLY_CHANNELS + 1):
        nco = int(round(float(_channel_value(per_channel_nco_hz, channel, 0.0))))
        if not RFDC_NCO_MIN_HZ <= nco <= RFDC_NCO_MAX_HZ:
            raise ParameterRangeError(
                f"RFDC CH{channel} nco_hz must be in [{RFDC_NCO_MIN_HZ}, {RFDC_NCO_MAX_HZ}]"
            )
        zone = int(_channel_value(per_channel_nyquist_zone, channel, 1))
        if zone not in (1, 2):
            raise ParameterRangeError(f"RFDC CH{channel} nyquist_zone must be 1 or 2")
        phase = normalize_rfdc_phase_mdeg(float(_channel_value(per_channel_phase_deg, channel, 0.0)))
        current_ua = int(round(float(_channel_value(per_channel_output_current_ma, channel, 20.0)) * 1000.0))
        current_min, current_max = ((6400, 32000) if channel in (5, 6) else (2250, 40500))
        if not current_min <= current_ua <= current_max:
            coupling = "DC" if channel in (5, 6) else "AC"
            raise ParameterRangeError(
                f"RFDC CH{channel} {coupling}-coupled DAC current must be in [{current_min / 1000:g}, {current_max / 1000:g}] mA"
            )
        payload += struct.pack("<qIiII", nco, zone, phase, current_ua, 0)
    if len(payload) != RFDC_APPLY_REQUEST_HEADER_BYTES + RFDC_APPLY_CHANNELS * RFDC_APPLY_REQUEST_ENTRY_BYTES:
        raise AssertionError("RFDC apply request packing produced an unexpected size")
    return pack_rfctrl2_packet(RF2_OP_RFDC_APPLY, payload, seq=seq)


def pack_rfctrl2_rfdc_get_config(seq: int = 1) -> bytes:
    return pack_rfctrl2_packet(RF2_OP_RFDC_GET_CONFIG, seq=seq)


def _ipv4_u32(value: str) -> int:
    try:
        return struct.unpack("!I", socket.inet_aton(str(value)))[0]
    except (OSError, struct.error) as exc:
        raise ParameterRangeError(f"invalid IPv4 address: {value}") from exc


def _u32_ipv4(value: int) -> str:
    return socket.inet_ntoa(struct.pack("!I", int(value) & 0xFFFFFFFF))


def _mac_u64(value: str) -> int:
    raw = str(value).replace(":", "").replace("-", "")
    if len(raw) != 12:
        raise ParameterRangeError(f"invalid MAC address: {value}")
    try:
        parsed = int(raw, 16) & 0xFFFFFFFFFFFF
    except ValueError as exc:
        raise ParameterRangeError(f"invalid MAC address: {value}") from exc
    if parsed in (0, 0xFFFFFFFFFFFF) or ((parsed >> 40) & 1):
        raise ParameterRangeError(f"invalid unicast MAC address: {value}")
    return parsed


def _u64_mac(value: int) -> str:
    raw = f"{int(value) & 0xFFFFFFFFFFFF:012x}"
    return ":".join(raw[index:index + 2] for index in range(0, 12, 2))


def pack_rfctrl2_network_apply(
    revision: int, ip: str, mac: str, subnet_mask: str = "255.255.255.0",
    gateway: str = "0.0.0.0", port: int = 1234, seq: int = 1,
) -> bytes:
    if not 1 <= int(port) <= 65535:
        raise ParameterRangeError(f"invalid UDP port: {port}")
    payload = struct.pack(
        "<IIQIIHHI", int(revision) & 0xFFFFFFFF, _ipv4_u32(ip), _mac_u64(mac),
        _ipv4_u32(subnet_mask), _ipv4_u32(gateway), int(port), 0, 0,
    )
    return pack_rfctrl2_packet(RF2_OP_NETWORK_APPLY, payload, seq=seq)


def pack_rfctrl2_network_get(seq: int = 1) -> bytes:
    return pack_rfctrl2_packet(RF2_OP_NETWORK_GET, seq=seq)


def pack_rfctrl2_network_restart(seq: int = 1) -> bytes:
    return pack_rfctrl2_packet(RF2_OP_NETWORK_RESTART, seq=seq)


def parse_rfresp2_packet(packet: bytes, *, validate_version: bool = True) -> dict[str, int | bytes]:
    raw = bytes(packet)
    if len(raw) < 24:
        raise ProtocolError("RFRESP2 packet is too short")
    magic, hdr0, hdr1 = struct.unpack_from("<QQQ", raw)
    if magic != UDP_RFRESP2_MAGIC:
        raise ProtocolError(f"unexpected RFRESP2 magic 0x{magic:016X}")
    version = hdr0 & 0xFFFF
    if validate_version and version != RFCTRL2_VERSION:
        raise ProtocolVersionError(f"RFRESP2 protocol version {version} is not supported (expected {RFCTRL2_VERSION})")
    payload_bytes = (hdr1 >> 32) & 0xFFFFFFFF
    if len(raw) < 24 + payload_bytes:
        raise ProtocolError(f"RFRESP2 payload is truncated: expected {payload_bytes} bytes")
    return {
        "version": version,
        "status": (hdr0 >> 16) & 0xFFFF,
        "opcode": (hdr0 >> 32) & 0xFFFFFFFF,
        "flags": (hdr0 >> 16) & 0xFFFF,
        "seq": hdr1 & 0xFFFFFFFF,
        "payload_bytes": payload_bytes,
        "payload": raw[24:24 + payload_bytes],
    }


def parse_rfctrl2_status_payload(response: Mapping) -> dict:
    payload = bytes(response.get("payload", b""))
    result = dict(response)
    result.update({
        "capabilities": 0, "state_flags": 0, "config_valid_mask": 0,
        "last_revision": 0, "last_error": 0, "last_error_stage": 0,
        "last_error_addr": 0, "play_config_channel_mask": 0,
        "play_fifo_valid_mask": 0, "play_fifo_ready_mask": 0,
        "play_executor_state": 0, "play_ddr_read_counter": 0,
        "play_bad_instr_count": 0, "play_prefill_ready": False,
        "play_active_valid": False, "play_pending_valid": False,
        "dac_mts_required": False, "dac_mts_ready": False,
        "dac_mts_failed": False, "dac_mts_tile_mask": 0, "dac_mts_error": 0,
        "nco_sync_ready": False, "nco_sync_epoch": 0,
        "sync_status": 0, "sync_role": "slave", "sync_mode": "external",
        "sync_seen": False, "sync_link_ready": False,
        "trigger_input_count": 0, "trigger_accepted_count": 0,
        "trigger_output_count": 0,
    })
    if len(payload) >= 32:
        (
            result["capabilities"], result["state_flags"], result["config_valid_mask"],
            result["last_revision"], result["last_error"], result["last_error_stage"],
            result["last_error_addr"], _reserved,
        ) = struct.unpack_from("<IIIIIIII", payload)
    if len(payload) >= 64:
        play_config, play_ready, play_counters, play_flags = struct.unpack_from("<QQQQ", payload, 32)
        result["play_config_channel_mask"] = play_config & 0xFF
        result["play_fifo_valid_mask"] = (play_config >> 32) & 0xFF
        result["play_fifo_ready_mask"] = play_ready & 0xFF
        result["play_executor_state"] = (play_ready >> 32) & 0xFF
        result["play_ddr_read_counter"] = play_counters & 0xFFFFFFFF
        result["play_bad_instr_count"] = (play_counters >> 32) & 0xFFFFFFFF
        result["play_prefill_ready"] = bool(play_flags & 1)
        result["play_pending_valid"] = bool((play_flags >> 32) & 1)
        result["play_active_valid"] = bool((play_flags >> 33) & 1)
    if len(payload) >= 72:
        mts_flags, result["nco_sync_epoch"] = struct.unpack_from("<II", payload, 64)
        result["dac_mts_ready"] = bool(mts_flags & 1)
        result["dac_mts_failed"] = bool(mts_flags & 2)
        result["dac_mts_required"] = bool(mts_flags & 4)
        result["dac_mts_tile_mask"] = (mts_flags >> 4) & 0xF
        result["dac_mts_error"] = (mts_flags >> 16) & 0xFFFF
    if len(payload) >= 80:
        result["sync_status"] = struct.unpack_from("<I", payload, 72)[0]
        result["sync_seen"] = bool(result["sync_status"] & RF2_SYNC_STATUS_SEEN)
        result["sync_link_ready"] = bool(result["sync_status"] & RF2_SYNC_STATUS_READY)
        result["sync_mode"] = "bypass" if result["sync_status"] & RF2_SYNC_STATUS_BYPASS else "external"
        result["sync_role"] = "master" if result["sync_status"] & RF2_SYNC_STATUS_ROLE_MASTER else "slave"
    if len(payload) >= 88:
        result["trigger_input_count"], result["trigger_accepted_count"] = struct.unpack_from("<II", payload, 80)
    if len(payload) >= 96:
        result["trigger_output_count"] = struct.unpack_from("<I", payload, 88)[0]
    result["rfdc_ready"] = bool(result["state_flags"] & RF2_STATUS_RFDC_READY)
    result["rfdc_busy"] = bool(result["state_flags"] & RF2_STATUS_RFDC_BUSY)
    result["armed"] = bool(result["state_flags"] & RF2_STATUS_ARMED)
    result["running"] = bool(result["state_flags"] & RF2_STATUS_RUNNING)
    result["prepared"] = bool(result["state_flags"] & RF2_STATUS_PREPARED)
    result["dac_mts_ready"] = result["dac_mts_ready"] or bool(result["state_flags"] & RF2_STATUS_DAC_MTS_READY)
    result["dac_mts_failed"] = result["dac_mts_failed"] or bool(result["state_flags"] & RF2_STATUS_DAC_MTS_FAILED)
    result["nco_sync_ready"] = bool(result["state_flags"] & RF2_STATUS_NCO_SYNC_READY)
    result["dac_mts_required"] = result["dac_mts_required"] or bool(result["state_flags"] & RF2_STATUS_DAC_MTS_REQUIRED)
    return result


def parse_rfctrl2_rfdc_config_response(response: Mapping) -> dict:
    payload = bytes(response.get("payload", b""))
    result = dict(response)
    result.update({"revision": 0, "applied_mask": 0, "error_mask": 0, "config_valid_mask": 0,
                   "failure_stage": 0, "failure_address": 0, "axi_response": 0,
                   "state_flags": 0, "channels": []})
    if not payload and int(result.get("status", RF2_STATUS_BAD_REQUEST)) != RF2_STATUS_OK:
        return result
    expected = RFDC_APPLY_RESPONSE_HEADER_BYTES + RFDC_APPLY_CHANNELS * RFDC_APPLY_RESPONSE_ENTRY_BYTES
    if len(payload) != expected:
        raise ProtocolError(f"RFDC response payload must be {expected} bytes, got {len(payload)}")
    (
        result["revision"], result["applied_mask"], result["error_mask"], result["config_valid_mask"],
        result["failure_stage"], result["failure_address"], result["axi_response"], result["state_flags"],
    ) = struct.unpack_from("<IIIIIIII", payload)
    offset = RFDC_APPLY_RESPONSE_HEADER_BYTES
    for channel in range(1, RFDC_APPLY_CHANNELS + 1):
        nco, zone, phase, current, channel_status, nco_word, phase_word, vop_code = struct.unpack_from(
            "<qIiIIQII", payload, offset
        )
        result["channels"].append({
            "channel": channel, "nco_hz": nco, "nyquist_zone": zone,
            "nco_phase_mdeg": phase, "nco_phase_deg": phase / 1000.0,
            "dac_output_current_ua": current, "dac_output_current_ma": current / 1000.0,
            "status": channel_status, "nco_word": nco_word, "phase_word": phase_word,
            "vop_code": vop_code,
        })
        offset += RFDC_APPLY_RESPONSE_ENTRY_BYTES
    return result


def parse_rfctrl2_network_response(response: Mapping) -> dict:
    """Decode the optional network discovery response used by the web console."""
    payload = bytes(response.get("payload", b""))
    result = dict(response)
    result.update({"device_uid": "", "current_ip": "", "current_mac": "",
                   "bootstrap_ip": "192.168.254.254", "revision": 0, "port": 1234,
                   "status_flags": 0, "capabilities": 0, "bootstrap_mac": "",
                   "subnet_mask": "255.255.255.0", "gateway": "0.0.0.0", "link_state": 0,
                   "build_profile_id": RF2_BUILD_PROFILE_UNKNOWN, "build_profile": "",
                   "playback_state": 0, "playback_armed": False, "playback_prepared": False,
                   "playback_running": False, "rfdc_config_valid_mask": 0,
                   "hmc_done": False, "sync_done": False})
    if not payload and int(result.get("status", RF2_STATUS_BAD_REQUEST)) != RF2_STATUS_OK:
        return result
    if len(payload) not in {NETWORK_RESPONSE_BYTES, NETWORK_EXT_RESPONSE_BYTES}:
        raise ProtocolError(f"network response payload must be {NETWORK_RESPONSE_BYTES} or {NETWORK_EXT_RESPONSE_BYTES} bytes, got {len(payload)}")
    words = struct.unpack("<" + "Q" * (len(payload) // 8), payload)
    result.update({
        "device_uid": f"{words[0]:016x}",
        "current_ip": _u32_ipv4(words[1] & 0xFFFFFFFF),
        "bootstrap_ip": _u32_ipv4((words[1] >> 32) & 0xFFFFFFFF),
        "current_mac": _u64_mac(words[2]),
        "revision": words[3] & 0xFFFFFFFF,
        "port": (words[3] >> 32) & 0xFFFF,
        "link_state": (words[3] >> 48) & 0xFFFF,
        "capabilities": words[4] & 0xFFFFFFFF,
        "status_flags": (words[4] >> 32) & 0xFFFFFFFF,
        "bootstrap_mac": _u64_mac(words[5]),
        "subnet_mask": _u32_ipv4(words[6]),
        "gateway": _u32_ipv4(words[7]),
    })
    if len(words) >= 10:
        result["build_profile_id"] = words[8] & 0xFFFFFFFF
        result["build_profile"] = RF2_BUILD_PROFILE_NAMES.get(result["build_profile_id"], "")
        result["playback_state"] = (words[8] >> 32) & 0xFFFFFFFF
        result["rfdc_config_valid_mask"] = words[9] & 0xFF
    result["playback_armed"] = bool(result["playback_state"] & RF2_STATUS_ARMED)
    result["playback_prepared"] = bool(result["playback_state"] & RF2_STATUS_PREPARED)
    result["playback_running"] = bool(result["playback_state"] & RF2_STATUS_RUNNING)
    result["hmc_done"] = bool(result["status_flags"] & RF2_NET_STATUS_HMC_DONE)
    result["sync_done"] = bool(result["status_flags"] & RF2_NET_STATUS_SYNC_DONE)
    return result


def align_bytes_to_beat(n_bytes: int) -> int:
    n = int(n_bytes)
    if n < 0:
        raise ParameterRangeError("byte length must be non-negative")
    return n + ((-n) % BEAT_BYTES)


def require_beat_aligned(value: int, name: str = "value") -> int:
    value = int(value)
    if value % BEAT_BYTES:
        raise ParameterRangeError(f"{name} must be {BEAT_BYTES}B aligned, got 0x{value:X}")
    return value


__all__ = [name for name in globals() if name.startswith(("RF", "UDP_", "DDR_", "PLAY_", "CHANNEL_", "WAVE", "pack_", "parse_", "align_", "require_", "normalize_", "validate_"))] + [
    "BEAT_BYTES", "FIXED_DATA_BYTES", "CHANNEL_ROLES", "DDR_BASE", "DDR_TILE_BYTES", "DDR_TILE_CHANNELS",
]
