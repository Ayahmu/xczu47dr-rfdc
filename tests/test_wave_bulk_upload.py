"""Bulk waveform upload: wire format and driver flow.

The image travels in UDP datagrams to the control port + 1, each one a 22-byte
bulk header followed by whole 64-byte DDR words.  There is no per-datagram
acknowledgement: the board counts words per 1 MiB chunk, and the driver asks
which chunk is short, gives it a new epoch and resends only that chunk.
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "software"))

import dr47.protocol as protocol  # noqa: E402
from dr47.errors import DeviceStatusError, ParameterRangeError  # noqa: E402
from dr47.simulator import SimulatedDr47Device  # noqa: E402

MIB = 1 << 20


# ---------------------------------------------------------------- wire format

def test_bulk_frame_is_tag_header_and_whole_words():
    payload = bytes(range(64)) * 16
    frame = protocol.pack_wave_bulk_frame(session=0x11223344, byte_offset=3 * MIB + 2048,
                                          payload=payload, epoch=5)
    assert len(frame) == 22 + 1024
    assert frame[:4] == b"WBLK"
    session, offset, words, epoch = struct.unpack_from("<IQHB", frame, 4)
    assert (session, offset, words, epoch) == (0x11223344, 3 * MIB + 2048, 16, 5)
    assert frame[19:22] == b"\x00\x00\x00"
    assert frame[22:] == payload


def test_bulk_header_fills_the_first_512_bit_word_with_the_network_headers():
    # Ethernet 14 + IPv4 20 + UDP 8 + bulk header = one 64-byte word, so the
    # payload starts on a word boundary inside the FPGA.
    assert 14 + 20 + 8 + protocol.WAVE_BULK_HEADER_BYTES == 64


@pytest.mark.parametrize("kwargs", [
    dict(byte_offset=0, payload=b""),                       # empty
    dict(byte_offset=0, payload=bytes(100)),                # not whole words
    dict(byte_offset=0, payload=bytes(8192 + 64)),          # more than 128 words
    dict(byte_offset=32, payload=bytes(64)),                # offset not word aligned
    dict(byte_offset=MIB - 64, payload=bytes(128)),         # crosses a chunk boundary
])
def test_bulk_frame_rejects_what_the_board_would_drop(kwargs):
    with pytest.raises(ParameterRangeError):
        protocol.pack_wave_bulk_frame(session=1, epoch=0, **kwargs)


def test_begin_accepts_the_bulk_layout_only():
    packet = protocol.pack_wave_begin(session=1, total_bytes=256, channel_mask=1, total_beats=1,
                                      layout=protocol.WAVE_LAYOUT_INTERLEAVED_512B_BULK)
    assert packet[24 + 13] == 2
    with pytest.raises(ParameterRangeError):
        protocol.pack_wave_begin(session=1, total_bytes=256, channel_mask=1, total_beats=1, layout=3)


def test_bulk_query_packets():
    status = protocol.pack_wave_bulk_status(session=7, seq=9)
    assert struct.unpack_from("<QQQ", status) == (protocol.WAVE_CTRL_MAGIC, (9 << 32) | 1, (4 << 32) | 9)
    assert struct.unpack_from("<I", status, 24) == (7,)

    reset = protocol.pack_wave_bulk_chunk_reset(session=7, chunk=2, epoch=3, seq=10)
    assert struct.unpack_from("<QQQ", reset) == (protocol.WAVE_CTRL_MAGIC, (10 << 32) | 1, (8 << 32) | 10)
    assert struct.unpack_from("<II", reset, 24) == (7, (3 << 13) | 2)
    for bad in (dict(chunk=8192, epoch=0), dict(chunk=0, epoch=256)):
        with pytest.raises(ParameterRangeError):
            protocol.pack_wave_bulk_chunk_reset(session=7, **bad)


def _bulk_response(opcode: int, *, ack: int, first_incomplete: int) -> bytes:
    # Same field values as tests/tb_waveform_response_serializer_bulk.sv.
    payload = struct.pack("<IIIIIQ", 5, 1, 0, 0, 0, 0x66666666_55555555)
    payload += struct.pack("<IIQQII", ack, first_incomplete, 0x22222222_11111111,
                           0x44444444_33333333, 0x77777777, 0)
    header = struct.pack("<QQQ", protocol.WAVE_RESP_MAGIC, (opcode << 32) | 1, (60 << 32) | 0x77)
    return header + payload + bytes(4)


@pytest.mark.parametrize("opcode", [protocol.WAVE_OP_BULK_STATUS, protocol.WAVE_OP_BULK_CHUNK_RESET])
def test_bulk_response_decodes_the_board_counters(opcode):
    done = protocol.parse_wave_response(_bulk_response(opcode, ack=0x8000_0003, first_incomplete=0xFFFF_FFFF))
    assert done["bulk_complete"] is True and done["bulk_overrun"] is False and done["bulk_axi_error"] is False
    assert done["bulk_complete_chunks"] == 3
    assert done["bulk_first_incomplete_chunk"] is None
    assert (done["bulk_frames_ok"], done["bulk_frames_rejected"]) == (0x11111111, 0x22222222)
    assert (done["bulk_frames_duplicate"], done["bulk_frames_stale"]) == (0x33333333, 0x44444444)
    assert (done["bulk_rx_frames"], done["bulk_rx_dropped_full"], done["bulk_rx_dropped_bad"]) == (
        0x55555555, 0x66666666, 0x77777777)

    short = protocol.parse_wave_response(_bulk_response(opcode, ack=0x6000_0001, first_incomplete=2))
    assert short["bulk_complete"] is False and short["bulk_overrun"] is True and short["bulk_axi_error"] is True
    assert short["bulk_complete_chunks"] == 1 and short["bulk_first_incomplete_chunk"] == 2


# ---------------------------------------------------------------- driver flow

def _image(nbytes: int) -> bytes:
    return (np.arange(nbytes // 2, dtype=np.uint32) * 2654435761 >> 7).astype("<u2").tobytes()


def _board() -> SimulatedDr47Device:
    board = SimulatedDr47Device()
    board.connect()
    return board


def test_bulk_upload_commits_the_exact_image():
    board = _board()
    image = _image(5 * MIB // 2)                 # 2.5 MiB: the last chunk is partial
    result = board.upload_image_bulk(image, session=3, channel_mask=0xFF,
                                     total_beats=len(image) // 256, loop_count=1)
    assert result["transport"] == "bulk"
    assert result["resent_chunks"] == []
    assert result["frames"] == len(image) // 1024
    assert bytes(board.sim_ddr_image()) == image
    assert board.waveform_status()["state_name"] == "prefetch"


def test_bulk_upload_resends_only_the_chunks_that_lost_frames():
    board = _board()
    image = _image(4 * MIB)
    board.sim_drop_bulk_frames({(5 * 1024, 0), (3 * MIB + 7 * 1024, 0)})   # (offset, epoch) lost once
    result = board.upload_image_bulk(image, session=4, channel_mask=1,
                                     total_beats=len(image) // 256, loop_count=1)
    assert result["resent_chunks"] == [0, 3]
    assert result["frames"] == 4 * 1024 + 2 * 1024      # two whole chunks sent again
    assert bytes(board.sim_ddr_image()) == image
    status = board.bulk_status(session=4)
    assert status["bulk_complete"] is True and status["bulk_complete_chunks"] == 4


def test_bulk_upload_reports_only_its_own_dropped_frames():
    board = _board()
    image = _image(2 * MIB)
    board.sim_drop_bulk_frames({(5 * 1024, 0)})
    first = board.upload_image_bulk(image, session=5, channel_mask=1,
                                    total_beats=len(image) // 256, loop_count=1)
    assert (first["rx_dropped_full"], first["rx_dropped_bad"]) == (1, 0)

    board.sim_drop_bulk_frames(None)
    second = board.upload_image_bulk(image, session=6, channel_mask=1,
                                     total_beats=len(image) // 256, loop_count=1)
    # The board's link counters run from power-up: the frame lost earlier is still in them.
    assert board.bulk_status(session=6)["bulk_rx_dropped_full"] == 1
    assert (second["rx_dropped_full"], second["rx_dropped_bad"]) == (0, 0)


def test_bulk_upload_gives_up_when_a_chunk_never_completes():
    board = _board()
    image = _image(2 * MIB)
    board.sim_drop_bulk_frames(lambda offset, epoch: offset == MIB + 2048)   # always lost
    with pytest.raises(DeviceStatusError):
        board.upload_image_bulk(image, session=5, channel_mask=1,
                                total_beats=len(image) // 256, loop_count=1, max_resends_per_chunk=3)
    assert board.waveform_status()["state_name"] != "prefetch"
    assert board.sim_bulk_chunk_resets() == [(1, 1), (1, 2), (1, 3)]


def test_a_frame_from_an_old_epoch_is_not_counted():
    board = _board()
    board.begin_waveform(session=6, total_bytes=MIB, channel_mask=1, total_beats=MIB // 256,
                         layout=protocol.WAVE_LAYOUT_INTERLEAVED_512B_BULK)
    board.bulk_chunk_reset(session=6, chunk=0, epoch=1)
    board.sim_receive_bulk_frame(protocol.pack_wave_bulk_frame(session=6, byte_offset=0, payload=bytes(1024), epoch=0))
    board.sim_receive_bulk_frame(protocol.pack_wave_bulk_frame(session=6, byte_offset=1024, payload=bytes(1024), epoch=1))
    status = board.bulk_status(session=6)
    assert (status["bulk_frames_stale"], status["bulk_frames_ok"]) == (1, 1)


def test_upload_waveforms_picks_the_transport():
    wave = np.zeros(16 * 4, dtype=np.int16)                    # 4 beats: tiny
    board = _board()
    assert board.upload_waveforms({1: wave}, wave_formats={1: "interleaved_iq"})["transport"] == "packet"

    big = np.zeros(16 * (8 * MIB // 256), dtype=np.int16)      # 8 MiB image
    board = _board()
    result = board.upload_waveforms({1: big}, wave_formats={1: "interleaved_iq"})
    assert result["transport"] == "bulk" and result["bytes"] == 8 * MIB

    # A bitstream without the bulk path refuses the bulk BEGIN; fall back.
    board = _board()
    board.sim_bulk_supported = False
    result = board.upload_waveforms({1: big}, wave_formats={1: "interleaved_iq"}, bulk_threshold_bytes=4096)
    assert result["transport"] == "packet"

    board = _board()
    assert board.upload_waveforms({1: wave}, wave_formats={1: "interleaved_iq"},
                                  transport="bulk")["transport"] == "bulk"
    board = _board()
    board.sim_bulk_supported = False
    with pytest.raises(DeviceStatusError):
        board.upload_waveforms({1: wave}, wave_formats={1: "interleaved_iq"}, transport="bulk")


# ---------------------------------------------------------------- real sockets

def _receive_bulk(receiver, count):
    got = {}
    receiver.settimeout(2.0)
    for _ in range(count):
        datagram = receiver.recv(65535)
        assert datagram[:4] == b"WBLK"
        session, offset, words, epoch = struct.unpack_from("<IQHB", datagram, 4)
        assert len(datagram) == 22 + 64 * words
        got[offset] = (session, epoch, datagram[22:])
    return got


@pytest.mark.parametrize("accelerate", [False, True], ids=["python", "c"])
@pytest.mark.parametrize("threads", [1, 2])
def test_bulk_sender_puts_one_frame_in_each_datagram(threads, accelerate):
    import socket
    import dr47.bulk as bulk
    from dr47.bulk import BulkSender

    if accelerate and bulk.load_fastsend() is None:
        pytest.skip("no C compiler to build the fast sender")
    image = _image(65536 + 256)                  # the last datagram is short
    receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    receiver.bind(("127.0.0.1", 0))
    sender = BulkSender("127.0.0.1", receiver.getsockname()[1], threads=threads, accelerate=accelerate)
    assert sender.accelerated is accelerate
    try:
        frames = sender.send(image, 0, len(image), session=9, epoch=4, payload_bytes=1024)
        assert frames == 65
        got = _receive_bulk(receiver, frames)
        # A middle range, as used when one chunk is sent again.
        assert sender.send(image, 4096, 8192, session=9, epoch=5, payload_bytes=1024) == 4
        again = _receive_bulk(receiver, 4)
    finally:
        sender.close()
        receiver.close()
    assert sorted(got) == list(range(0, len(image), 1024))
    assert all(session == 9 and epoch == 4 for session, epoch, _ in got.values())
    assert b"".join(got[offset][2] for offset in sorted(got)) == image
    assert sorted(again) == [4096, 5120, 6144, 7168]
    assert all(epoch == 5 and again[o][2] == image[o:o + 1024] for o, (_, epoch, _) in again.items())


@pytest.mark.parametrize("accelerate", [False, True], ids=["python", "c"])
def test_bulk_sender_threads_share_one_socket(accelerate):
    """One socket means one network-card transmit queue, so each thread's
    batch reaches the board as an unbroken run of neighbouring addresses.
    Separate sockets get interleaved frame by frame, and the board then has to
    switch DDR4 rows for every frame, which it cannot do at line rate."""
    import socket
    import dr47.bulk as bulk
    from dr47.bulk import BulkSender

    if accelerate and bulk.load_fastsend() is None:
        pytest.skip("no C compiler to build the fast sender")
    image = _image(256 * 1024)
    receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    receiver.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    receiver.bind(("127.0.0.1", 0))
    receiver.settimeout(2.0)
    sender = BulkSender("127.0.0.1", receiver.getsockname()[1], threads=3, accelerate=accelerate)
    try:
        assert sender.send(image, 0, len(image), session=1, epoch=0, payload_bytes=1024) == 256
        sources, offsets = set(), []
        for _ in range(256):
            datagram, source = receiver.recvfrom(65535)
            sources.add(source)
            offsets.append(struct.unpack_from("<Q", datagram, 8)[0])
    finally:
        sender.close()
        receiver.close()
    assert len(sources) == 1
    assert sorted(offsets) == list(range(0, len(image), 1024))


@pytest.mark.parametrize("accelerate", [False, True], ids=["python", "c"])
def test_bulk_sender_gathers_the_lanes_while_sending(accelerate):
    """The channel arrays go straight to the wire; no full image is built."""
    import socket
    import dr47.bulk as bulk
    from dr47.bulk import BulkSender
    from dr47.waveforms import LaneImage

    if accelerate and bulk.load_fastsend() is None:
        pytest.skip("no C compiler to build the fast sender")
    rng = np.random.default_rng(8)
    waves = {1: rng.integers(-32768, 32767, 16384, dtype=np.int16),
             3: rng.integers(-32768, 32767, 5001, dtype=np.int16),      # ends inside a lane, mid image
             8: rng.integers(-32768, 32767, 16000, dtype=np.int16)}
    lanes = LaneImage(waves)
    expected = lanes.pack().tobytes()
    assert len(expected) == 262144
    receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    receiver.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    receiver.bind(("127.0.0.1", 0))
    sender = BulkSender("127.0.0.1", receiver.getsockname()[1], threads=3, accelerate=accelerate)
    try:
        assert sender.send(lanes, 0, len(lanes), session=2, epoch=0, payload_bytes=1024) == 256
        got = _receive_bulk(receiver, 256)
        assert sender.send(lanes, 65536, 65536 + 3072, session=2, epoch=1, payload_bytes=1024) == 3
        again = _receive_bulk(receiver, 3)
    finally:
        sender.close()
        receiver.close()
    assert b"".join(got[offset][2] for offset in sorted(got)) == expected
    assert sorted(again) == [65536, 66560, 67584]
    assert all(again[o][2] == expected[o:o + 1024] and again[o][1] == 1 for o in again)


def test_upload_waveforms_does_not_build_the_image_for_the_bulk_path(monkeypatch):
    from dr47.waveforms import LaneImage, pack_interleaved_512b_image

    rng = np.random.default_rng(9)
    waves = {1: rng.integers(-32768, 32767, 16 * (2 * MIB // 256), dtype=np.int16),
             6: rng.integers(-32768, 32767, 1000, dtype=np.int16)}
    formats = {1: "interleaved_iq", 6: "interleaved_iq"}
    expected = pack_interleaved_512b_image(waves)[0].tobytes()

    largest = {"bytes": 0}
    real_pack = LaneImage.pack

    def watched_pack(self, start=0, end=None):
        block = real_pack(self, start, end)
        largest["bytes"] = max(largest["bytes"], block.size)
        return block
    monkeypatch.setattr(LaneImage, "pack", watched_pack)
    board = _board()
    result = board.upload_waveforms(waves, wave_formats=formats, transport="bulk")
    assert result["transport"] == "bulk" and result["bytes"] == len(expected) == 2 * MIB
    assert bytes(board.sim_ddr_image()) == expected
    assert 0 < largest["bytes"] <= 65536          # only what one batch needs, never the whole image

    # A masked channel still sets the length and plays zeros.
    board = _board()
    result = board.upload_waveforms(waves, wave_formats=formats, channel_mask=0x20, transport="bulk")
    assert result["bytes"] == 2 * MIB
    assert bytes(board.sim_ddr_image()) == pack_interleaved_512b_image({6: waves[6], 1: np.zeros_like(waves[1])})[0].tobytes()


def test_bulk_payload_follows_the_interface_mtu(tmp_path, monkeypatch):
    import dr47.bulk as bulk

    assert bulk.payload_bytes_for_interface("") == 1024
    mtu = {"value": "9000"}
    monkeypatch.setattr(bulk.Path, "read_text", lambda self: mtu["value"])
    assert bulk.payload_bytes_for_interface("eth9") == 8192
    mtu["value"] = "1500"
    assert bulk.payload_bytes_for_interface("eth9") == 1024
    mtu["value"] = "4200"
    assert bulk.payload_bytes_for_interface("eth9") == 4096


def test_bulk_sender_works_without_the_c_library(monkeypatch):
    import socket
    import dr47.bulk as bulk

    monkeypatch.setattr(bulk, "load_fastsend", lambda: None)
    receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    receiver.bind(("127.0.0.1", 0))
    sender = bulk.BulkSender("127.0.0.1", receiver.getsockname()[1])
    try:
        assert sender.accelerated is False
        assert sender.send(_image(4096), 0, 4096, session=1, epoch=0, payload_bytes=1024) == 4
        assert sorted(_receive_bulk(receiver, 4)) == [0, 1024, 2048, 3072]
    finally:
        sender.close()
        receiver.close()
    with pytest.raises(bulk.TransportError):
        bulk.BulkSender("127.0.0.1", 9, accelerate=True)


def test_fast_sender_is_not_built_when_disabled(monkeypatch):
    import dr47.bulk as bulk

    monkeypatch.setenv("DR47_FASTSEND", "0")
    monkeypatch.setattr(bulk, "_fastsend_lib", bulk._UNSET)
    assert bulk.load_fastsend() is None
