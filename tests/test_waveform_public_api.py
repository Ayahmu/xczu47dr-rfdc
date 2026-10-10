"""Contract tests for the single-board WAVECTR0 public API.

The waveform target deliberately has no software master/slave, XS20, or
instruction-schedule playback API.  RFDC configuration and independent
hardware diagnostics remain separate APIs; this test only guards the public
waveform driver surface.
"""

from __future__ import annotations

import inspect
import struct
from dataclasses import fields
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "software"))

import dr47  # noqa: E402
import dr47.protocol as protocol  # noqa: E402
import host  # noqa: E402
import waveform_tools  # noqa: E402
from dr47.capabilities import DeviceCapabilities  # noqa: E402
from dr47.device import Dr47Device  # noqa: E402
from dr47.hardware_test_network import BoardNetworkAssignment, EnrolledBoard  # noqa: E402
from dr47.protocol import (  # noqa: E402
    RF2_STATUS_OK, RFCTRL2_VERSION, RFDC_APPLY_CHANNELS, RFDC_APPLY_RESPONSE_ENTRY_BYTES,
    RFDC_APPLY_RESPONSE_HEADER_BYTES,
)
from dr47.simulator import SimulatedDr47Device  # noqa: E402


LEGACY_DRIVER_METHODS = (
    "set_sync_role",
    "set_sync_mode",
    "bypass_sync",
    "require_external_sync",
    "sync",
    "emit_trigger",
    "rfctrl2_set_sync_role",
    "rfctrl2_emit_trigger",
    "configure_playback",
    "abort_mute",
)


@pytest.mark.parametrize("method_name", LEGACY_DRIVER_METHODS)
def test_single_board_driver_does_not_expose_retired_playback_methods(method_name: str):
    assert not hasattr(Dr47Device, method_name)
    assert not hasattr(SimulatedDr47Device, method_name)


def test_driver_exposes_no_gain_or_dac_current_setting():
    for cls in (Dr47Device, SimulatedDr47Device):
        assert not hasattr(cls, "set_gain")
        assert "output_current_ma" not in inspect.signature(cls.apply_rfdc_config).parameters
        assert "per_channel_output_current_ma" not in inspect.signature(cls.rfctrl2_rfdc_apply).parameters


def test_host_and_driver_use_the_same_fixed_dac_current():
    assert host._FIXED_DAC_OUTPUT_CURRENT_MA == protocol._FIXED_DAC_OUTPUT_CURRENT_MA
    assert protocol._FIXED_DAC_OUTPUT_CURRENT_MA == {
        channel: (32.0 if channel in (5, 6) else 40.5) for channel in range(1, 9)}


class _RecordingTransport:
    """Injected transport that records RFCTRL2 requests and acknowledges them."""

    def __init__(self):
        self.sent = []

    def request(self, packet, *, seq, opcode, retries, wait_response):
        self.sent.append(packet)
        payload = bytes(RFDC_APPLY_RESPONSE_HEADER_BYTES + RFDC_APPLY_CHANNELS * RFDC_APPLY_RESPONSE_ENTRY_BYTES)
        return {"version": RFCTRL2_VERSION, "status": RF2_STATUS_OK, "opcode": opcode,
                "seq": seq, "payload_bytes": len(payload), "payload": payload}


def _requested_currents_ua(packet: bytes) -> list[int]:
    # 24 B RFCTRL2 header, revision + channel mask, then eight (q I i I I) entries.
    return [struct.unpack_from("<qIiII", packet, 32 + 24 * channel)[3] for channel in range(8)]


def test_every_rfdc_apply_requests_the_fixed_maximum_dac_current():
    transport = _RecordingTransport()
    device = Dr47Device(ip="192.0.2.10", transport=transport, batch_mode=True)
    device._connected = True
    device.set_xy_target_frequency(1, 0.5)
    device.commit()
    device.apply_rfdc_config(nco_ghz={1: 0.2})
    assert len(transport.sent) == 2
    for packet in transport.sent:
        assert _requested_currents_ua(packet) == [40500] * 4 + [32000] * 2 + [40500] * 2


def test_single_board_constructor_and_capabilities_have_no_sync_role_contract():
    assert "sync_role" not in inspect.signature(Dr47Device).parameters
    assert "sync_role" not in inspect.signature(SimulatedDr47Device).parameters
    for name in ("sync_role", "sync_mode", "sync_link_ready"):
        assert not hasattr(DeviceCapabilities, name)


def test_hardware_enrollment_uses_single_board_identity_not_sync_role():
    assignment_fields = {field.name for field in fields(BoardNetworkAssignment)}
    enrolled_fields = {field.name for field in fields(EnrolledBoard)}
    assert "sync_role" not in assignment_fields
    assert "sync_role" not in enrolled_fields


def test_single_board_package_does_not_export_retired_schedule_types():
    for name in (
        "BurstSchedule", "QuantizedBurstSchedule", "PlaybackConfig",
        "pack_udp_instruction_packet", "sequence_to_play_commands",
        "iter_interleaved_udp_bulk_packets", "make_burst_record",
    ):
        assert not hasattr(dr47, name)
        assert name not in getattr(dr47, "__all__", ())


def test_protocol_does_not_expose_retired_sync_playback_opcodes():
    for name in (
        "RF2_OP_SET_SYNC_ROLE", "RF2_OP_EMIT_TRIGGER",
        "RF2_SYNC_ROLE_SLAVE", "RF2_SYNC_ROLE_MASTER",
        "RF2_SYNC_MODE_EXTERNAL", "RF2_SYNC_MODE_BYPASS",
        "pack_rfctrl2_set_sync_role", "pack_rfctrl2_emit_trigger",
    ):
        assert not hasattr(protocol, name)


def test_single_board_host_surface_does_not_expose_retired_playback_paths():
    for name in (
        "pack_rfctrl2_arm", "pack_rfctrl2_trigger", "pack_rfctrl2_abort_mute",
    ):
        assert not hasattr(host, name)
    for name in (
        "rfctrl2_arm", "rfctrl2_trigger", "rfctrl2_abort_mute",
        "upload_waveform", "upload_waveform_udp",
        "upload_waveform_udp_tiled", "upload_waveform_udp_interleaved",
        "upload_waveform_interleaved", "send_instructions",
    ):
        assert not hasattr(host.RFSocController, name)
    assert not hasattr(waveform_tools, "build_play_commands")
    assert not hasattr(waveform_tools, "build_ezq_upload_plan")


def test_host_cli_uses_descriptor_upload_and_waveform_play(tmp_path, monkeypatch):
    calls = []

    class FakeDevice:
        def __init__(self, *args, **kwargs):
            calls.append(("init", args, kwargs))

        def connect(self):
            calls.append(("connect",))

        def upload_waveforms(self, channel_waves, *, channel_mask, loop_count, wave_formats=None):
            calls.append(("upload_waveforms", sorted(channel_waves), channel_mask, loop_count, wave_formats))
            return {"session": 9, "total_beats": 2, "packet_count": 1}

        def play(self, *, session):
            calls.append(("play", session))

        def close(self):
            calls.append(("close",))

    monkeypatch.setattr(host, "Dr47Device", FakeDevice)
    monkeypatch.setattr(host, "plot_tone", lambda *args, **kwargs: None)
    monkeypatch.setattr(
        host,
        "parse_args",
        lambda: type("Args", (), {
            "ip": "192.0.2.10", "port": 1234, "transport": "udp", "timeout": 1.0,
            "tone_bytes": 64, "tone_amp": 0.25, "channels": "1,3", "dry_run": False,
            "output_dir": str(tmp_path), "wait_for_trigger": False,
            "udp_write_settle_s": 0.0, "udp_interface": "eth0", "udp_source_ip": "192.0.2.1",
            "ddr_layout": host.DDR_LAYOUT_INTERLEAVED_512B,
        })(),
    )

    assert host.main() == 0
    assert [call[0] for call in calls] == ["init", "connect", "upload_waveforms", "play", "close"]
    upload = calls[2]
    assert upload[1] == [1, 3]
    assert upload[2] == 0x05
    assert upload[3] == 1
    assert upload[4] == {1: "interleaved_iq", 3: "interleaved_iq"}
