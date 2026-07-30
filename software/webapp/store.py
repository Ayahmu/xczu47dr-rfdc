from __future__ import annotations

import json
import sqlite3
import threading
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path

from .models import RunCreateRequest, RunEvent, RunRecord, RunState


def utc_now() -> str:
    return datetime.now(UTC).isoformat()


class RunStore:
    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path)
        connection.row_factory = sqlite3.Row
        return connection

    @contextmanager
    def _connection(self):
        connection = self._connect()
        try:
            yield connection
            connection.commit()
        finally:
            connection.close()

    def _initialize(self) -> None:
        with self._connection() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS runs (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    state TEXT NOT NULL,
                    dry_run INTEGER NOT NULL,
                    board_ids TEXT NOT NULL,
                    start_mode TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    artifact_dir TEXT NOT NULL,
                    progress REAL NOT NULL,
                    error TEXT NOT NULL,
                    request_json TEXT NOT NULL,
                    completion_mode TEXT NOT NULL DEFAULT 'upload',
                    playback_mode TEXT NOT NULL DEFAULT 'single',
                    loaded INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    run_id TEXT NOT NULL,
                    timestamp TEXT NOT NULL,
                    level TEXT NOT NULL,
                    message TEXT NOT NULL
                );
                """
            )
            self._ensure_column(connection, "runs", "completion_mode", "TEXT NOT NULL DEFAULT 'upload'")
            self._ensure_column(connection, "runs", "playback_mode", "TEXT NOT NULL DEFAULT 'single'")
            self._ensure_column(connection, "runs", "loaded", "INTEGER NOT NULL DEFAULT 0")
            # Dry runs only generate and validate host artifacts. Older versions
            # incorrectly marked them as if data had been uploaded to a board.
            connection.execute("UPDATE runs SET loaded=0 WHERE dry_run=1 AND loaded!=0")

    @staticmethod
    def _ensure_column(connection: sqlite3.Connection, table: str, column: str, definition: str) -> None:
        columns = {row[1] for row in connection.execute(f"PRAGMA table_info({table})").fetchall()}
        if column not in columns:
            connection.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")

    def create(self, run_id: str, request: RunCreateRequest, artifact_dir: Path) -> RunRecord:
        now = utc_now()
        record = RunRecord(
            id=run_id,
            name=request.jobs[0].waveform.name,
            state=RunState.QUEUED,
            dry_run=request.dry_run,
            board_ids=request.board_ids,
            start_mode="trigger",
            execution_mode=request.execution_mode,
            completion_mode=request.completion_mode,
            playback_mode=request.playback_mode,
            created_at=now,
            updated_at=now,
            artifact_dir=str(artifact_dir),
        )
        with self._lock, self._connection() as connection:
            connection.execute(
                """INSERT INTO runs(
                    id, name, state, dry_run, board_ids, start_mode, created_at,
                    updated_at, artifact_dir, progress, error, request_json,
                    completion_mode, playback_mode, loaded
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    record.id,
                    record.name,
                    record.state.value,
                    int(record.dry_run),
                    json.dumps(record.board_ids),
                    record.start_mode,
                    record.created_at,
                    record.updated_at,
                    record.artifact_dir,
                    record.progress,
                    record.error,
                    request.model_dump_json(),
                    request.completion_mode,
                    request.playback_mode,
                    0,
                ),
            )
        return record

    def update(self, run_id: str, state: RunState, progress: float, error: str = "") -> RunRecord:
        with self._lock, self._connection() as connection:
            connection.execute(
                "UPDATE runs SET state=?, progress=?, error=?, updated_at=? WHERE id=?",
                (state.value, progress, error, utc_now(), run_id),
            )
        record = self.get(run_id)
        if record is None:
            raise KeyError(run_id)
        return record

    def set_loaded(self, run_id: str, loaded: bool) -> RunRecord:
        with self._lock, self._connection() as connection:
            connection.execute("UPDATE runs SET loaded=?, updated_at=? WHERE id=?", (int(loaded), utc_now(), run_id))
        record = self.get(run_id)
        if record is None:
            raise KeyError(run_id)
        return record

    def complete_loaded(self, run_id: str, state: RunState = RunState.DONE) -> RunRecord:
        """Commit the loaded flag and terminal upload state in one transaction."""
        with self._lock, self._connection() as connection:
            connection.execute(
                "UPDATE runs SET loaded=1, state=?, progress=1.0, updated_at=? WHERE id=?",
                (state.value, utc_now(), run_id),
            )
        record = self.get(run_id)
        if record is None:
            raise KeyError(run_id)
        return record

    def complete_unloaded(self, run_id: str) -> RunRecord:
        """Complete artifact generation without claiming that hardware was loaded."""
        with self._lock, self._connection() as connection:
            connection.execute(
                "UPDATE runs SET loaded=0, state=?, progress=1.0, updated_at=? WHERE id=?",
                (RunState.DONE.value, utc_now(), run_id),
            )
        record = self.get(run_id)
        if record is None:
            raise KeyError(run_id)
        return record

    def finish_one_shot(self, run_id: str) -> RunRecord:
        """Commit the terminal one-shot state after the board has been muted."""
        with self._lock, self._connection() as connection:
            connection.execute(
                "UPDATE runs SET loaded=0, state=?, progress=1.0, updated_at=? WHERE id=?",
                (RunState.DONE.value, utc_now(), run_id),
            )
        record = self.get(run_id)
        if record is None:
            raise KeyError(run_id)
        return record

    def recover_orphaned(self, active_ids: set[str]) -> list[RunRecord]:
        with self._lock, self._connection() as connection:
            rows = connection.execute(
                "SELECT id FROM runs WHERE state IN ('QUEUED','GENERATING','UPLOADING','READY','ARMED','RUNNING')"
            ).fetchall()
            orphan_ids = [row["id"] for row in rows if row["id"] not in active_ids]
            for run_id in orphan_ids:
                connection.execute(
                    "UPDATE runs SET state='ABORTED', error=?, updated_at=? WHERE id=?",
                    ("server restart recovered an orphaned run", utc_now(), run_id),
                )
        return [record for run_id in orphan_ids if (record := self.get(run_id)) is not None]

    def get_request(self, run_id: str) -> RunCreateRequest:
        with self._connection() as connection:
            row = connection.execute("SELECT request_json FROM runs WHERE id=?", (run_id,)).fetchone()
        if row is None:
            raise KeyError(run_id)
        return RunCreateRequest.model_validate_json(row["request_json"])

    def get(self, run_id: str) -> RunRecord | None:
        with self._connection() as connection:
            row = connection.execute("SELECT * FROM runs WHERE id=?", (run_id,)).fetchone()
        return self._record(row) if row is not None else None

    def list(self, limit: int = 50) -> list[RunRecord]:
        with self._connection() as connection:
            rows = connection.execute("SELECT * FROM runs ORDER BY created_at DESC LIMIT ?", (limit,)).fetchall()
        return [self._record(row) for row in rows]

    def add_event(self, run_id: str, message: str, level: str = "info") -> RunEvent:
        event = RunEvent(run_id=run_id, timestamp=utc_now(), level=level, message=message)
        with self._lock, self._connection() as connection:
            connection.execute(
                "INSERT INTO events(run_id, timestamp, level, message) VALUES (?, ?, ?, ?)",
                (event.run_id, event.timestamp, event.level, event.message),
            )
        return event

    def events(self, run_id: str) -> list[RunEvent]:
        with self._connection() as connection:
            rows = connection.execute("SELECT run_id, timestamp, level, message FROM events WHERE run_id=? ORDER BY id", (run_id,)).fetchall()
        return [RunEvent.model_validate(dict(row)) for row in rows]

    @staticmethod
    def _record(row: sqlite3.Row) -> RunRecord:
        return RunRecord(
            id=row["id"],
            name=row["name"],
            state=RunState(row["state"]),
            dry_run=bool(row["dry_run"]),
            board_ids=json.loads(row["board_ids"]),
            start_mode=row["start_mode"],
            execution_mode="single",
            created_at=row["created_at"],
            updated_at=row["updated_at"],
            artifact_dir=row["artifact_dir"],
            progress=float(row["progress"]),
            error=row["error"],
            completion_mode=row["completion_mode"] if "completion_mode" in row.keys() else "upload",
            playback_mode=row["playback_mode"] if "playback_mode" in row.keys() else "single",
            loaded=bool(row["loaded"]) if "loaded" in row.keys() else False,
        )
