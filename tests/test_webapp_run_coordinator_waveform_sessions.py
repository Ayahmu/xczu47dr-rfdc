from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

from software.webapp.controller import EventHub, RunCoordinator
from software.webapp.models import RunRecord, RunState


class _Store:
    def __init__(self, record: RunRecord, request: object) -> None:
        self.record = record
        self.request = request

    def recover_orphaned(self, _active_ids: set[str]):
        return []

    def get(self, run_id: str):
        return self.record if run_id == self.record.id else None

    def get_request(self, run_id: str):
        assert run_id == self.record.id
        return self.request

    def set_waveform_sessions(self, run_id: str, sessions: dict[str, int]):
        assert run_id == self.record.id
        self.record = self.record.model_copy(update={"waveform_sessions": dict(sessions)})
        return self.record


def _record(*, state: RunState, loaded: bool = True, sessions: dict[str, int] | None = None) -> RunRecord:
    return RunRecord(
        id="123456789abc",
        name="waveform session test",
        state=state,
        dry_run=False,
        board_ids=["board-a"],
        created_at="2026-09-19T00:00:00+00:00",
        updated_at="2026-09-19T00:00:00+00:00",
        artifact_dir="/tmp/waveform-session-test",
        loaded=loaded,
        waveform_sessions=sessions or {},
    )


def _request():
    channels = [SimpleNamespace(channel=channel, enabled=channel == 1) for channel in range(1, 9)]
    job = SimpleNamespace(
        board_id="board-a",
        waveform=SimpleNamespace(mode="manual", manual_channels=channels),
        override=None,
    )
    return SimpleNamespace(jobs=[job], board_ids=["board-a"], execution_mode="single", playback_mode="single")


def _coordinator(record: RunRecord):
    store = _Store(record, _request())
    boards = Mock()
    boards.simulation = False
    coordinator = RunCoordinator(store, boards, Path("/tmp"), EventHub())
    coordinator._event = Mock()
    coordinator._publish_run = Mock()
    coordinator._fault = Mock()
    return coordinator, store, boards


def test_loaded_waveform_lifecycle_uses_persisted_session_for_every_command():
    coordinator, _store, boards = _coordinator(
        _record(state=RunState.DONE, loaded=True, sessions={"board-a": 0x1234})
    )

    coordinator.arm_loaded("123456789abc")
    boards.arm.assert_called_once_with("board-a", session=0x1234)

    boards.reset_mock()
    coordinator.trigger_loaded("123456789abc")
    boards.manual_trigger.assert_called_once_with("board-a", session=0x1234, expect_sustained=False)

    boards.reset_mock()
    coordinator.abort_loaded("123456789abc")
    boards.mute.assert_called_once_with("board-a", session=0x1234)


def test_run_actions_reject_missing_session_instead_of_using_run_id():
    coordinator, _store, boards = _coordinator(_record(state=RunState.ARMED, sessions={}))

    try:
        coordinator.start("123456789abc")
    except RuntimeError as exc:
        assert "waveform session" in str(exc)
    else:
        raise AssertionError("start must reject a run without a persisted waveform session")
    boards.manual_trigger.assert_not_called()


def test_live_upload_session_is_persisted_and_simulation_gets_stable_identity():
    coordinator, store, boards = _coordinator(_record(state=RunState.UPLOADING, loaded=False))

    result = SimpleNamespace(upload_result={"session": 0x2345, "descriptor": 7})
    updated = coordinator._record_waveform_session("123456789abc", "board-a", result)
    assert updated.waveform_sessions == {"board-a": 0x2345}
    assert store.record.waveform_sessions == {"board-a": 0x2345}
    boards.register_waveform_session.assert_not_called()

    simulation_coordinator, _simulation_store, simulation_boards = _coordinator(
        _record(state=RunState.UPLOADING, loaded=False)
    )
    simulation_boards.simulation = True
    result = SimpleNamespace(upload_result=None)
    updated = simulation_coordinator._record_waveform_session("123456789abc", "board-a", result)
    session = updated.waveform_sessions["board-a"]
    assert session != 0
    simulation_boards.register_waveform_session.assert_called_once()
    registered = simulation_boards.register_waveform_session.call_args.args
    assert registered[0] == "board-a"
    assert registered[1] == session
    assert registered[2] != 0
