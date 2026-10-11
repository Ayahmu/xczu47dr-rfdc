"""100G stress example: a clean line-rate load, its verdict and the HTML report.

The example runs here against the simulator, with a sender that feeds it frame
by frame and a clock on which only sending and waiting take time, so the load
has a known number of passes and no hardware is needed.
"""

from __future__ import annotations

import importlib
import json
import re
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "software"))

import dr47  # noqa: E402
from dr47.simulator import SimulatedDr47Device  # noqa: E402

stress = importlib.import_module("dr47.examples.waveform_100g_stress_example")

MIB = 1 << 20
PAYLOAD_BYTES = 1024
PASS_S = 0.5                      # sending one pass
POLL_S = 0.001                    # one look at a socket that still holds frames


class Clock:
    """The example's `time`: sending, waiting and sleeping are all that take time."""

    def __init__(self) -> None:
        self.now = 1000.0

    def perf_counter(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds

    def __getattr__(self, name: str):
        return getattr(time, name)


class Rig:
    """The simulator as the board, plus the sender that feeds it.

    `drops[n]` is the number of frames the board's FIFO drops in pass n.  The
    last `late_frames` of a pass are still in the host's transmit queue when
    the counter query that follows it is answered.  After a pass the socket
    holds frames for `drain_polls` looks (None: for ever).
    """

    def __init__(self, clock: Clock, drops=(), late_frames: int = 0, drain_polls: int | None = 2) -> None:
        self.clock = clock
        self.drops = list(drops)
        self.late_frames = late_frames
        self.drain_polls = drain_polls
        self.waiting = 0              # looks left until the socket is empty
        self.sends = []               # (start, end, frames still in the socket when the pass began)
        self.pending = None
        self.device = None
        self.sender_options = None

    def make_device(self, **kwargs) -> SimulatedDr47Device:
        device = self.device = SimulatedDr47Device(**kwargs)
        answer = device.bulk_status

        def bulk_status(*, session: int):
            status = answer(session=session)
            self.deliver_pending()
            return status

        device.bulk_status = bulk_status
        return device

    def deliver_pending(self) -> None:
        if self.pending is not None:
            pending, self.pending = self.pending, None
            self.device._bulk_send(*pending[0], **pending[1])

    def make_sender(self, *args, **options) -> "Rig":
        self.sender_options = options
        return self

    def queued_bytes(self) -> int:
        if self.drain_polls is None and self.sends:
            self.clock.now += POLL_S
            return 4096
        if self.waiting:
            self.waiting -= 1
            self.clock.now += POLL_S
            return 4096
        return 0

    def send(self, image, start: int, end: int, *, session: int, epoch: int, payload_bytes: int) -> int:
        dropped = self.drops[len(self.sends)] if len(self.sends) < len(self.drops) else 0
        self.sends.append((start, end, self.waiting))
        # The drops fall on the last frames of the pass.
        first_dropped = end - dropped * payload_bytes
        self.device.sim_drop_bulk_frames(lambda offset, _epoch: offset >= first_dropped)
        cut = end - self.late_frames * payload_bytes
        frames = self.device._bulk_send(image, start, cut, session=session, epoch=epoch,
                                        payload_bytes=payload_bytes)
        if self.late_frames:
            self.pending = ((image, cut, end), dict(session=session, epoch=epoch, payload_bytes=payload_bytes))
            frames += self.late_frames
        self.clock.now += PASS_S
        self.waiting = self.drain_polls or 0
        return frames

    def close(self) -> None:
        pass


@pytest.fixture
def rig(monkeypatch, tmp_path):
    clock = Clock()

    def build(**kwargs) -> Rig:
        rig = Rig(clock, **kwargs)
        monkeypatch.setattr(stress, "Dr47Device", rig.make_device)
        monkeypatch.setattr(stress, "BulkSender", rig.make_sender)
        return rig

    monkeypatch.setattr(stress, "time", clock)
    monkeypatch.setattr(stress, "nic_frames_sent", lambda: None)
    monkeypatch.setattr(stress, "payload_bytes_for_interface", lambda interface: PAYLOAD_BYTES)
    monkeypatch.setattr(stress, "IMAGE_MIB", 1)
    monkeypatch.setattr(stress, "DURATION_S", 4 * PASS_S)           # four passes
    monkeypatch.setattr(stress, "MIN_WIRE_RATE_GBPS", 0.0)          # the rig is far from line rate
    monkeypatch.setattr(stress, "REPORT_DIR", str(tmp_path))
    return build


def load(rig: Rig) -> dict:
    device = rig.make_device(ip="127.0.0.1")
    device.connect()
    return stress.run_load(device, stress.make_image(), PAYLOAD_BYTES, session=1)


# ---------------------------------------------------------------- the load

def test_load_keeps_one_cumulative_timeline_row_per_pass(rig):
    measured = load(rig(drops=[0, 3, 0, 12], drain_polls=0))

    assert measured["passes"] == 4
    assert measured["elapsed_s"] == pytest.approx(4 * PASS_S)
    # time since the load began, then frames sent / fifo_full / bad_fcs / rejected so far
    assert measured["timeline"] == [
        [pytest.approx(0.5), 1024, 0, 0, 0],
        [pytest.approx(1.0), 2048, 3, 0, 0],
        [pytest.approx(1.5), 3072, 3, 0, 0],
        [pytest.approx(2.0), 4096, 15, 0, 0],
    ]


def test_load_totals_and_rates_match_what_the_board_counted(rig, monkeypatch):
    monkeypatch.setattr(stress, "SENDER_THREADS", 3)
    measured = load(rig(drops=[0, 3, 0, 12], drain_polls=0))

    assert (measured["threads"], measured["sent"], measured["board_rx"]) == (3, 4096, 4096)
    assert (measured["bad_fcs"], measured["fifo_full"], measured["rejected"], measured["stored"]) == (0, 15, 0, 4081)
    assert measured["loss_rate"] == pytest.approx(15 / 4096)
    assert measured["goodput_gbps"] == pytest.approx(4096 * 1024 * 8 / 2.0 / 1e9)
    assert measured["wire_gbps"] == pytest.approx(4096 * 1112 * 8 / 2.0 / 1e9)
    assert measured["on_wire"] is None


def test_drops_counted_after_the_last_query_still_reach_the_timeline(rig):
    # The dropped frames of every pass are among the 16 that arrive after the
    # query, so the last pass's drops only show up while the load settles.
    measured = load(rig(drops=[0, 3, 0, 12], late_frames=16, drain_polls=0))

    assert measured["fifo_full"] == 15
    assert measured["timeline"][-1] == [pytest.approx(2.0), measured["sent"], 15, 0, 0]


# ---------------------------------------------------------------- a clean sender

def test_every_pass_starts_with_an_empty_socket(rig):
    """With frames still waiting, a queue switch by the kernel interleaves them
    with the next pass and the board drops frames the hardware did not lose."""
    board = rig(drain_polls=2)

    measured = load(board)

    assert [waiting for _, _, waiting in board.sends] == [0, 0, 0, 0]
    assert measured["drain_wait_ms"] == pytest.approx(2 * POLL_S * 1000)


def test_a_socket_that_never_empties_stops_the_load(rig):
    with pytest.raises(RuntimeError, match="did not send"):
        load(rig(drain_polls=None))


def test_a_pass_is_at_most_one_slice_of_the_image(rig, monkeypatch):
    """A pass has to end well inside a second, whatever the image size."""
    monkeypatch.setattr(stress, "IMAGE_MIB", 3)
    monkeypatch.setattr(stress, "MAX_PASS_BYTES", MIB)
    board = rig(drain_polls=0)

    measured = load(board)

    assert [(start // MIB, end // MIB) for start, end, _ in board.sends] == [(0, 1), (1, 2), (2, 3), (0, 1)]
    assert (measured["passes"], measured["sent"], measured["stored"]) == (4, 4096, 4096)


def test_sender_gets_the_bounded_send_buffer_and_the_threads(rig, monkeypatch):
    monkeypatch.setattr(stress, "SENDER_THREADS", 3)
    board = rig()

    load(board)

    assert board.sender_options["send_buffer_bytes"] == stress.SEND_BUFFER_BYTES == MIB
    assert board.sender_options["threads"] == 3


# ---------------------------------------------------------------- verdict

def measured(**values) -> dict:
    return {"wire_gbps": 99.4, "elapsed_s": 20.2, "sent": 4096, "on_wire": 4100, "board_rx": 4096,
            "bad_fcs": 0, "fifo_full": 0, "rejected": 0, "stored": 4096, "loss_rate": 0.0, **values}


@pytest.fixture
def limits(monkeypatch):
    monkeypatch.setattr(stress, "MIN_WIRE_RATE_GBPS", 99.0)
    monkeypatch.setattr(stress, "MAX_LOSS_RATE", 0.0)
    monkeypatch.setattr(stress, "host_setting", lambda name: 4 * MIB)


def test_a_full_link_without_loss_passes(limits):
    assert stress.verdict(measured()) == (True, "99.4 Gb/s on the wire for 20 s, 0 of 4096 frames lost")


def test_a_single_lost_frame_fails_and_says_where(limits):
    passed, message = stress.verdict(measured(board_rx=4095, bad_fcs=1, fifo_full=3, rejected=2, stored=4089,
                                              loss_rate=7 / 4096))

    assert not passed
    assert message.startswith("7 of 4096 frames lost")
    assert "not delivered=1, bad_fcs=1, fifo_full=3, rejected=2" in message


def test_a_link_the_host_did_not_fill_is_not_a_hardware_result(limits):
    passed, message = stress.verdict(measured(wire_gbps=93.7))

    assert not passed
    assert "93.7 Gb/s" in message and "MIN_WIRE_RATE_GBPS=99" in message
    assert "does not show" in message
    assert "wmem_max" not in message


def test_a_small_socket_buffer_limit_is_named_when_the_link_is_not_full(limits, monkeypatch):
    monkeypatch.setattr(stress, "host_setting", lambda name: 212992)

    _, message = stress.verdict(measured(wire_gbps=89.0))

    assert "net.core.wmem_max=212992" in message


def test_frames_the_host_dropped_are_not_counted_against_the_board(limits):
    passed, message = stress.verdict(measured(on_wire=4000, board_rx=4000, stored=4000, loss_rate=96 / 4096))

    assert not passed
    assert message.startswith("the host dropped 96 frames")


def test_loss_is_reported_even_when_the_link_was_not_full(limits):
    _, message = stress.verdict(measured(wire_gbps=50.0, fifo_full=1, stored=4095, loss_rate=1 / 4096))

    assert message.startswith("1 of 4096 frames lost")


# ---------------------------------------------------------------- report files

def embedded_data(page: Path) -> dict:
    html = page.read_text(encoding="utf-8")
    block = re.search(r'<script type="application/json" id="report-data">(.*?)</script>', html, re.S)
    return json.loads(block.group(1))


def test_report_is_one_self_contained_page_carrying_the_run(monkeypatch, tmp_path):
    monkeypatch.setattr(stress, "REPORT_DIR", str(tmp_path))
    result = {
        "started": "2026-10-11 15:30:12", "passed": True,
        # Text from the board or an exception must not be able to end the data block.
        "message": "99.4 Gb/s </script><script>alert(1)</script><!-- ",
        "measured": {"threads": 4, "timeline": [[0.5, 1024, 0, 0, 0]]},
    }

    page = stress.write_report(result)

    assert page == tmp_path / "stress_20261011_153012.html"
    assert embedded_data(page) == result
    assert json.loads(page.with_suffix(".json").read_text(encoding="utf-8")) == result
    # Nothing is fetched: no script, stylesheet, image or font from elsewhere.
    assert not re.search(r"(?:src|href)\s*=|@import|url\(", page.read_text(encoding="utf-8"))


def test_run_writes_a_report_and_prints_where(rig, tmp_path, capsys):
    rig()

    assert stress.run() == 0

    page, = tmp_path.glob("stress_*.html")
    output = capsys.readouterr().out
    assert f"report: {page}" in output
    data = embedded_data(page)
    assert data["passed"] is True and output.rstrip().splitlines()[-2] == "PASS: " + data["message"]
    assert (data["measured"]["passes"], data["measured"]["sent"], data["measured"]["stored"]) == (4, 4096, 4096)
    assert data["driver"] == dr47.__version__
    assert data["board"] == {"build_profile": "simulated_xczu47dr", "source_commit": "00000000"}
    assert data["config"]["payload_bytes"] == PAYLOAD_BYTES
    assert data["config"]["frame_wire_bytes"] == 1112
    assert data["config"]["duration_s"] == 4 * PASS_S
    assert data["config"]["send_buffer_bytes"] == stress.SEND_BUFFER_BYTES
    assert data["config"]["max_loss_rate"] == stress.MAX_LOSS_RATE
    assert data["config"]["min_wire_rate_gbps"] == 0.0


def test_lost_frames_fail_the_run_and_are_in_the_report(rig, tmp_path, capsys):
    rig(drops=[0, 2])

    assert stress.run() == 1

    page, = tmp_path.glob("stress_*.html")
    data = embedded_data(page)
    assert data["passed"] is False
    assert data["message"].startswith("2 of 4096 frames lost")
    assert data["measured"]["fifo_full"] == 2
    assert "FAIL: 2 of 4096 frames lost" in capsys.readouterr().out


def test_a_load_that_breaks_off_fails_without_a_report(rig, monkeypatch, tmp_path, capsys):
    board = rig()

    def make_device(**kwargs):
        device = board.make_device(**kwargs)
        answer = device.bulk_status
        # The DDR writer reports an error.
        device.bulk_status = lambda *, session: {**answer(session=session), "bulk_axi_error": True}
        return device

    monkeypatch.setattr(stress, "Dr47Device", make_device)

    assert stress.run() == 1

    assert list(tmp_path.iterdir()) == []
    assert "FAIL: DDR write error during the stress run" in capsys.readouterr().out


def test_empty_report_dir_writes_nothing(rig, tmp_path, monkeypatch, capsys):
    rig()
    monkeypatch.setattr(stress, "REPORT_DIR", "")
    monkeypatch.chdir(tmp_path)

    assert stress.run() == 0

    assert list(tmp_path.iterdir()) == []
    assert "report:" not in capsys.readouterr().out
