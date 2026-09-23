import struct
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[1] / "software"))
from dr47.protocol import (  # noqa: E402
    WAVE_OP_ABORT, WAVE_OP_BEGIN, WAVE_OP_COMMIT, WAVE_OP_DATA, WAVE_OP_PAUSE,
    WAVE_OP_PLAY, WAVE_OP_STATUS, WAVE_OP_STOP, WAVE_STATUS_OK, WAVE_STATUS_CRC, WAVE_STATUS_OFFSET, WAVE_STATUS_SEQUENCE,
    crc32,
    pack_wave_begin, pack_wave_data, pack_wave_command, parse_wave_response,
)
from dr47.simulator import SimulatedDr47Device  # noqa: E402
from dr47.capabilities import PlaybackState  # noqa: E402


def test_begin_data_commit_response_contract():
    begin = pack_wave_begin(session=7, total_bytes=256, channel_mask=0xFF,
                            total_beats=1, loop_count=3, seq=11)
    assert begin[:8] != struct.pack("<Q", 0)
    data = bytes(range(64))
    packet = pack_wave_data(session=7, packet_seq=0, byte_offset=0,
                            payload=data, seq=12)
    assert packet.endswith(data)
    assert crc32(data) == struct.unpack_from("<I", packet, 24 + 20)[0]


def test_simulator_rejects_gap_duplicate_is_idempotent_and_commit_starts_prefetch():
    board = SimulatedDr47Device()
    board.connect()
    data0 = bytes(range(32))
    data1 = bytes(range(32, 256))
    board.begin_waveform(session=9, total_bytes=256, channel_mask=0xFF,
                         total_beats=1, loop_count=1)
    gap = board.data_waveform(session=9, packet_seq=1, byte_offset=32, payload=data1)
    assert gap["status"] != WAVE_STATUS_OK
    board.data_waveform(session=9, packet_seq=0, byte_offset=0, payload=data0)
    board.data_waveform(session=9, packet_seq=0, byte_offset=0, payload=data0)
    board.data_waveform(session=9, packet_seq=1, byte_offset=32, payload=data1)
    result = board.commit_waveform(session=9)
    assert result["state"] == 3
    assert board.status(refresh=False).state is PlaybackState.PREFETCH


def test_play_pause_stop_abort_and_trigger_admission():
    board = SimulatedDr47Device()
    board.connect()
    board.begin_waveform(session=1, total_bytes=256, channel_mask=1,
                         total_beats=1, loop_count=1)
    board.data_waveform(session=1, packet_seq=0, byte_offset=0, payload=b"x" * 256)
    board.commit_waveform(session=1)
    board.complete_prefetch()
    assert board.status(refresh=False).state is PlaybackState.WAIT_TRIGGER
    board.play()
    assert board.status(refresh=False).state is PlaybackState.PLAYING
    board.pause()
    assert board.status(refresh=False).state is PlaybackState.READY
    board.trigger_event()
    assert board.status(refresh=False).state is PlaybackState.READY
    board.play()
    board.complete_prefetch()
    assert board.status(refresh=False).state is PlaybackState.PLAYING
    board.abort()
    assert board.status(refresh=False).state is PlaybackState.IDLE


def test_upload_errors_do_not_advance_progress_and_incomplete_commit_is_rejected():
    board = SimulatedDr47Device(); board.connect()
    board.begin_waveform(session=3, total_bytes=256, channel_mask=0x03, total_beats=1)
    first = b"a" * 32
    bad_crc = board.data_waveform(session=3, packet_seq=0, byte_offset=0, payload=first, payload_crc=0)
    assert bad_crc["status"] == WAVE_STATUS_CRC
    assert bad_crc["next_expected_sequence"] == 0
    assert bad_crc["received_bytes"] == 0
    bad_offset = board.data_waveform(session=3, packet_seq=0, byte_offset=8, payload=first)
    assert bad_offset["status"] == WAVE_STATUS_OFFSET
    gap = board.data_waveform(session=3, packet_seq=1, byte_offset=0, payload=first)
    assert gap["status"] == WAVE_STATUS_SEQUENCE
    incomplete = board.commit_waveform(session=3)
    assert incomplete["status"] != WAVE_STATUS_OK


def test_response_parser_exposes_common_identity_and_data_ack_fields():
    common = struct.pack("<IIIIIQ", 7, 4, 0, 0, 0x1234, 96)
    data_ack = struct.pack("<IIQQII", 12, 13, 2**32 + 4096, 2**32 + 96, 0x12345678, 0x87654321)
    hdr0 = (WAVE_OP_DATA << 32) | 1
    hdr1 = ((len(common) + len(data_ack)) << 32) | 77
    packet = struct.pack("<QQQ", 0x5741564552535030, hdr0, hdr1) + common + data_ack + b"\0" * 4
    parsed = parse_wave_response(packet)
    assert parsed["session"] == 7
    assert parsed["state_name"] == "wait_trigger"
    assert parsed["descriptor"] == 0x1234
    assert parsed["ack_packet_seq"] == 12
    assert parsed["next_expected_sequence"] == 13
    assert parsed["received_bytes"] == 2**32 + 4096
    assert parsed["first_error_offset"] == 2**32 + 96
    assert parsed["expected_crc"] == 0x12345678
    assert parsed["actual_crc"] == 0x87654321


def test_upload_waveforms_uses_one_uniform_interleaved_descriptor():
    import numpy as np
    board = SimulatedDr47Device(); board.connect()
    result = board.upload_waveforms({1: np.arange(16, dtype=np.int16), 5: np.arange(16, dtype=np.int16)},
                                    wave_formats={1: "interleaved_iq", 5: "z"},
                                    channel_mask=0x11, loop_count=2)
    assert result["channel_mask"] == 0x11
    assert result["total_beats"] >= 1
    assert board.status(refresh=False).state is PlaybackState.PREFETCH


from dr47.errors import ProtocolError, ParameterRangeError


def response_packet(opcode, body, declared=None):
    size = len(body) if declared is None else declared
    return struct.pack("<QQQ", 0x5741564552535030, (opcode << 32) | 1,
                       (size << 32) | 1) + body + bytes((-len(body)) % 8)


@pytest.mark.parametrize("extension_length", [0, 15, 16, 19, 20, 23, 31, 33])
def test_data_response_requires_exact_complete_extension(extension_length):
    body = struct.pack("<IIIIIQ", 1, 1, 0, 0, 1, 0) + bytes(extension_length)
    with pytest.raises(ProtocolError):
        parse_wave_response(response_packet(WAVE_OP_DATA, body))


@pytest.mark.parametrize("mutation", ["truncated", "extra", "padding", "state", "status"])
def test_malformed_response_is_protocol_error(mutation):
    body = struct.pack("<IIIIIQ", 1, 4 if mutation != "state" else 99,
                       0 if mutation != "status" else 2, 0, 2, 0)
    packet = response_packet(WAVE_OP_COMMIT, body)
    if mutation == "truncated": packet = packet[:-1]
    if mutation == "extra": packet += bytes(8)
    if mutation == "padding": packet = packet[:-1] + b"x"
    with pytest.raises(ProtocolError): parse_wave_response(packet)


def test_begin_golden_dac_beat_units_and_64_bit_bytes():
    packet = pack_wave_begin(session=7, total_bytes=2**32+256, channel_mask=1,
                             total_beats=2**24+1, loop_count=2, seq=0x12345678)
    assert packet == struct.pack("<QQQIQBBHIII", 0x5741564543545230,
        (1 << 32) | 1, (28 << 32) | 0x12345678,
        7, 2**32+256, 1, 1, 0, 2**24+1, 2, 64) + bytes(4)


@pytest.mark.parametrize("kwargs", [dict(total_bytes=64, total_beats=1),
    dict(loop_count=0), dict(layout=2), dict(total_beats=4), dict(total_beats=1.5)])
def test_begin_rejects_invalid_contract_before_sending(kwargs):
    args = dict(session=1,total_bytes=256,total_beats=1,channel_mask=1)
    args.update(kwargs)
    with pytest.raises(ParameterRangeError): pack_wave_begin(**args)


@pytest.mark.parametrize("kwargs", [dict(byte_offset=2**64),dict(session=2**32),
    dict(packet_seq=-1),dict(payload=bytes(31)),dict(payload=bytes(1440)),dict(seq=1.5)])
def test_data_fields_do_not_wrap_or_truncate(kwargs):
    args=dict(session=1,packet_seq=0,byte_offset=0,payload=bytes(32),seq=1)
    args.update(kwargs)
    with pytest.raises(ParameterRangeError): pack_wave_data(**args)


def test_stop_cancels_upload_and_pause_does_not_invent_descriptor():
    board = SimulatedDr47Device(); board.connect()
    board.begin_waveform(session=1,total_bytes=256,total_beats=1,channel_mask=1)
    assert board.pause()["status"] != 0
    result=board.stop()
    assert result["opcode"] == WAVE_OP_STOP
    assert result["state"] == 0 and result["session"] == 0 and result["descriptor"] == 0


def test_disabled_channels_are_zero_but_image_stride_does_not_shrink():
    import numpy as np
    board=SimulatedDr47Device();board.connect()
    result=board.upload_waveforms({1:np.arange(18,dtype=np.int16),2:np.ones(18,dtype=np.int16)},
                                 channel_mask=1)
    assert result["bytes"]==512 and result["total_beats"]==2
    image=np.frombuffer(board._wave_received,dtype="<i2").reshape(-1,8,4)
    assert not image[:,1:,:].any()
    assert np.array_equal(image[:,0,:].reshape(-1)[:18],np.arange(18))


def test_missing_status_is_not_a_successful_ack():
    from dr47.device import Dr47Device
    with pytest.raises(ProtocolError):
        Dr47Device._check_wave_response({}, "DATA")


@pytest.mark.parametrize("operation", ["play", "pause", "stop", "abort"])
def test_simulator_rejects_wrong_session_without_state_change(operation):
    board=SimulatedDr47Device(); board.connect()
    board.begin_waveform(session=3,total_bytes=256,total_beats=1,channel_mask=1)
    response=getattr(board,operation)(session=7)
    assert response["status"] != 0 and response["session"] == 3 and response["state"] == 1


def test_udp_wave_timeout_retransmits_identical_request():
    import socket
    from dr47.transport import UdpTransport
    class Socket:
        def __init__(self): self.sent=[];self.receives=0
        def settimeout(self,value): pass
        def setsockopt(self,*args): pass
        def sendto(self,packet,address): self.sent.append((packet,address));return len(packet)
        def recvfrom(self,size):
            self.receives+=1
            if self.receives==1: raise socket.timeout()
            body=struct.pack("<IIIIIQ",3,4,0,0,1,0)
            packet=response_packet(WAVE_OP_PLAY,body)
            return packet,("127.0.0.1",1234)
    sock=Socket();transport=UdpTransport("127.0.0.1",sock=sock)
    packet=pack_wave_command(WAVE_OP_PLAY,session=3,seq=1)
    result=transport.request_wave(packet,seq=1,opcode=WAVE_OP_PLAY,retries=1)
    assert result["seq"]==1 and sock.sent[0]==sock.sent[1]


def test_status_response_parser_exposes_consistent_playback_snapshot():
    common = struct.pack("<IIIIIQ", 7, 4, 0, 0, 0x1234, 96)
    extension = struct.pack(
        "<IIII8HIIIII",
        0x01020304, 0x05060708, 0x090A0B0C, 0x000001A5,
        0x0010, 0x0020, 0x0030, 0x0040, 0x0050, 0x0060, 0x0070, 0x0080,
        0x11121314, 0x15161718, 0x191A1B1C, 0x1D1E1F20, 0x21222324,
    )
    assert len(common + extension) == 80
    hdr0 = (WAVE_OP_STATUS << 32) | 1
    hdr1 = (80 << 32) | 77
    packet = struct.pack("<QQQ", 0x5741564552535030, hdr0, hdr1) + common + extension
    parsed = parse_wave_response(packet)
    assert parsed["payload_bytes"] == 80
    assert parsed["current_beat"] == 0x01020304
    assert parsed["loop_position"] == 0x05060708
    assert parsed["loop_count"] == 0x090A0B0C
    assert parsed["channel_mask"] == 0xA5
    assert parsed["layout"] == 1
    assert parsed["fifo_levels"] == (0x0010, 0x0020, 0x0030, 0x0040,
                                      0x0050, 0x0060, 0x0070, 0x0080)
    assert parsed["error_count"] == 0x11121314
    assert parsed["underflow_count"] == 0x15161718
    assert parsed["trigger_seen_count"] == 0x191A1B1C
    assert parsed["trigger_dropped_count"] == 0x1D1E1F20
    assert parsed["trigger_fire_count"] == 0x21222324


def test_upload_interleaved_chunks_commits_stream_without_instruction_playback():
    from dr47.device import Dr47Device

    class Recorder(Dr47Device):
        def __init__(self):
            super().__init__(transport=object())
            self.calls = []
            self._connected = True

        def begin_waveform(self, **kwargs):
            self.calls.append(("begin", kwargs))
            return {"status": WAVE_STATUS_OK, "state": 1}

        def data_waveform(self, **kwargs):
            self.calls.append(("data", kwargs))
            return {"status": WAVE_STATUS_OK, "state": 1}

        def commit_waveform(self, **kwargs):
            self.calls.append(("commit", kwargs))
            return {"status": WAVE_STATUS_OK, "state": 3, "descriptor": 9}

    board = Recorder()
    result = board.upload_interleaved_chunks(
        ((0, b"a" * 128), (128, b"b" * 128)),
        total_bytes=256,
        total_beats=1,
        channel_mask=0xFF,
        loop_count=2,
        session=17,
    )
    assert [name for name, _ in board.calls] == ["begin", "data", "data", "commit"]
    assert board.calls[0][1]["total_beats"] == 1
    assert board.calls[1][1]["byte_offset"] == 0
    assert board.calls[2][1]["byte_offset"] == 128
    assert result["session"] == 17
    assert result["descriptor"] == 9
