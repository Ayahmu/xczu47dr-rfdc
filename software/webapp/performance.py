from __future__ import annotations

import csv
import io
import json
import sqlite3
import sys
import threading
import time
import uuid
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path

SOFTWARE_DIR = Path(__file__).resolve().parents[1]
if str(SOFTWARE_DIR) not in sys.path:
    sys.path.insert(0, str(SOFTWARE_DIR))

from .models import (
    BoardRfdcConfig,
    BoardWaveformJob,
    ManualChannel,
    PerformancePointRecord,
    PerformanceTestCreateRequest,
    PerformanceTestRecord,
    RfdcConfigApplyRequest,
    RunCreateRequest,
    TestKind,
    TestSessionState,
    WaveformRequest,
)

import host


def utc_now() -> str:
    return datetime.now(UTC).isoformat()


class PerformanceStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=10)
        connection.row_factory = sqlite3.Row
        return connection

    @contextmanager
    def _connection(self):
        with self._lock:
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
                CREATE TABLE IF NOT EXISTS performance_tests (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    board_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    channel INTEGER NOT NULL,
                    channels_json TEXT NOT NULL,
                    mode TEXT NOT NULL,
                    state TEXT NOT NULL,
                    current_point INTEGER NOT NULL,
                    total_points INTEGER NOT NULL,
                    settle_ms REAL NOT NULL,
                    auto_mute INTEGER NOT NULL,
                    dry_run INTEGER NOT NULL,
                    error TEXT NOT NULL,
                    environment_json TEXT NOT NULL DEFAULT '{}',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS performance_points (
                    id TEXT PRIMARY KEY,
                    test_id TEXT NOT NULL REFERENCES performance_tests(id) ON DELETE CASCADE,
                    point_index INTEGER NOT NULL,
                    state TEXT NOT NULL,
                    parameters_json TEXT NOT NULL,
                    measurement_json TEXT NOT NULL,
                    error TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(test_id, point_index)
                );
                """
            )
            columns = {row[1] for row in connection.execute("PRAGMA table_info(performance_tests)").fetchall()}
            if "dry_run" not in columns:
                connection.execute("ALTER TABLE performance_tests ADD COLUMN dry_run INTEGER NOT NULL DEFAULT 1")
            if "environment_json" not in columns:
                connection.execute("ALTER TABLE performance_tests ADD COLUMN environment_json TEXT NOT NULL DEFAULT '{}'")

    def create(self, request: PerformanceTestCreateRequest, environment: dict[str, object] | None = None) -> PerformanceTestRecord:
        test_id, timestamp = uuid.uuid4().hex[:12], utc_now()
        with self._connection() as connection:
            connection.execute(
                """INSERT INTO performance_tests(
                    id, name, board_id, kind, channel, channels_json, mode, state,
                    current_point, total_points, settle_ms, auto_mute, dry_run,
                    error, environment_json, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 'DRAFT', 0, ?, ?, ?, ?, '', ?, ?, ?)""",
                (test_id, request.name, request.board_id, request.kind.value, request.channel,
                 json.dumps(request.channels or [request.channel]), request.mode, len(request.points),
                 request.settle_ms, int(request.auto_mute), int(request.dry_run),
                 json.dumps(environment or {}, ensure_ascii=False), timestamp, timestamp),
            )
            for index, parameters in enumerate(request.points):
                connection.execute(
                    "INSERT INTO performance_points VALUES (?, ?, ?, 'PENDING', ?, '{}', '', ?)",
                    (uuid.uuid4().hex[:12], test_id, index, json.dumps(parameters), timestamp),
                )
        return self.get(test_id)

    def get(self, test_id: str) -> PerformanceTestRecord:
        with self._connection() as connection:
            row = connection.execute("SELECT * FROM performance_tests WHERE id=?", (test_id,)).fetchone()
        if row is None:
            raise KeyError(f"unknown performance test {test_id}")
        return self._test(row)

    def list(self, limit: int = 100) -> list[PerformanceTestRecord]:
        with self._connection() as connection:
            rows = connection.execute("SELECT * FROM performance_tests ORDER BY created_at DESC LIMIT ?", (limit,)).fetchall()
        return [self._test(row) for row in rows]

    def update(self, test_id: str, **changes) -> PerformanceTestRecord:
        allowed = {"state", "current_point", "error", "environment_json"}
        fields = [(key, value) for key, value in changes.items() if key in allowed]
        if fields:
            clause = ", ".join(f"{key}=?" for key, _ in fields)
            values = [value.value if isinstance(value, TestSessionState) else value for _, value in fields]
            with self._connection() as connection:
                connection.execute(f"UPDATE performance_tests SET {clause}, updated_at=? WHERE id=?", (*values, utc_now(), test_id))
        return self.get(test_id)

    def update_environment(self, test_id: str, environment: dict[str, object]) -> PerformanceTestRecord:
        return self.update(test_id, environment_json=json.dumps(environment, ensure_ascii=False))

    def point(self, test_id: str, index: int) -> PerformancePointRecord:
        with self._connection() as connection:
            row = connection.execute("SELECT * FROM performance_points WHERE test_id=? AND point_index=?", (test_id, index)).fetchone()
        if row is None:
            raise KeyError(f"unknown performance point {test_id}/{index}")
        return self._point(row)

    def points(self, test_id: str) -> list[PerformancePointRecord]:
        with self._connection() as connection:
            rows = connection.execute("SELECT * FROM performance_points WHERE test_id=? ORDER BY point_index", (test_id,)).fetchall()
        return [self._point(row) for row in rows]

    def update_point(self, test_id: str, index: int, state: str, measurement: dict | None = None, error: str = "") -> PerformancePointRecord:
        with self._connection() as connection:
            connection.execute(
                "UPDATE performance_points SET state=?, measurement_json=?, error=?, updated_at=? WHERE test_id=? AND point_index=?",
                (state, json.dumps(measurement or {}), error, utc_now(), test_id, index),
            )
        return self.point(test_id, index)

    @staticmethod
    def _test(row: sqlite3.Row) -> PerformanceTestRecord:
        return PerformanceTestRecord(
            id=row["id"], name=row["name"], board_id=row["board_id"], kind=row["kind"], channel=row["channel"],
            channels=json.loads(row["channels_json"]), mode=row["mode"], state=row["state"],
            current_point=row["current_point"], total_points=row["total_points"], settle_ms=row["settle_ms"],
            auto_mute=bool(row["auto_mute"]), created_at=row["created_at"], updated_at=row["updated_at"], error=row["error"],
            dry_run=bool(row["dry_run"]),
            environment=json.loads(row["environment_json"]) if "environment_json" in row.keys() else {},
        )

    @staticmethod
    def _point(row: sqlite3.Row) -> PerformancePointRecord:
        return PerformancePointRecord(
            id=row["id"], test_id=row["test_id"], index=row["point_index"], state=row["state"],
            parameters=json.loads(row["parameters_json"]), measurement=json.loads(row["measurement_json"]),
            error=row["error"], updated_at=row["updated_at"],
        )


class PerformanceService:
    def __init__(self, store: PerformanceStore, management, runs, rfdc, events) -> None:
        self.store = store
        self.management = management
        self.runs = runs
        self.rfdc = rfdc
        self.events = events
        self._threads: dict[str, threading.Thread] = {}
        self._stop: dict[str, threading.Event] = {}
        self._loaded_runs: dict[str, str] = {}
        self._lock = threading.RLock()

    def shutdown(self, timeout_s: float = 30.0) -> None:
        """Stop automatic test workers before the application releases its database."""
        with self._lock:
            stops = tuple(self._stop.values())
            threads = tuple(self._threads.values())
        for stop in stops:
            stop.set()
        deadline = time.monotonic() + timeout_s
        for thread in threads:
            remaining = max(0.0, deadline - time.monotonic())
            thread.join(remaining)

    def create(self, request: PerformanceTestCreateRequest) -> PerformanceTestRecord:
        self.management.board(request.board_id)
        return self.store.create(request, self._environment_snapshot(request.board_id))

    def _environment_snapshot(self, board_id: str) -> dict[str, object]:
        board = self.management.board(board_id)
        config = self.rfdc.get(board_id)
        artifact = self.management.latest_successful_artifact(board_id)
        artifact_payload = artifact.model_dump(mode="json") if artifact else None
        return {
            "captured_at": utc_now(),
            "board_id": board_id,
            "board": board.model_dump(mode="json", exclude={"lease"}),
            "rfdc_config": config.model_dump(mode="json"),
            "bitstream": artifact_payload and {
                "name": artifact_payload["bit_name"],
                "sha256": artifact_payload["bit_sha256"],
                "size": artifact_payload["bit_size"],
            },
            "firmware": artifact_payload and {
                "name": artifact_payload["elf_name"],
                "sha256": artifact_payload["elf_sha256"],
                "size": artifact_payload["elf_size"],
            },
            "artifact": artifact_payload,
        }

    def start(self, test_id: str, automatic: bool | None = None) -> PerformanceTestRecord:
        test = self.store.get(test_id)
        if test.state not in {TestSessionState.DRAFT, TestSessionState.PAUSED}:
            raise ValueError(f"test {test_id} is already {test.state.value}")
        self.store.update_environment(test_id, self._environment_snapshot(test.board_id))
        self.store.update(test_id, state=TestSessionState.RUNNING, error="")
        if automatic is None:
            automatic = test.mode == "automatic"
        if automatic:
            stop = threading.Event()
            self._stop[test_id] = stop
            thread = threading.Thread(target=self._run_all, args=(test_id, stop), name=f"rfsoc-test-{test_id}", daemon=True)
            self._threads[test_id] = thread
            thread.start()
        return self.store.get(test_id)

    def pause(self, test_id: str) -> PerformanceTestRecord:
        test = self.store.get(test_id)
        if test.state != TestSessionState.RUNNING:
            raise ValueError("only a running test can be paused")
        stop = self._stop.get(test_id)
        if stop:
            stop.set()
        return self.store.update(test_id, state=TestSessionState.PAUSED)

    def abort(self, test_id: str) -> PerformanceTestRecord:
        test = self.store.get(test_id)
        stop = self._stop.get(test_id)
        if stop:
            stop.set()
        run_id = self._loaded_runs.pop(test_id, None)
        if run_id:
            try:
                self.runs.abort_loaded(run_id)
            except Exception:
                pass
        return self.store.update(test_id, state=TestSessionState.ABORTED)

    def execute_point(self, test_id: str, index: int) -> PerformancePointRecord:
        test = self.store.get(test_id)
        if not 0 <= index < test.total_points:
            raise ValueError("test point index is out of range")
        point = self.store.point(test_id, index)
        self.store.update_environment(test_id, self._environment_snapshot(test.board_id))
        self.store.update(test_id, state=TestSessionState.RUNNING, current_point=index)
        self.store.update_point(test_id, index, "RUNNING")
        self.events.publish({"type": "test.point.updated", "data": self.store.point(test_id, index).model_dump(mode="json")})
        try:
            generated_run = self._load_point(test, point)
            if not test.dry_run:
                self.runs.play_loaded(generated_run.id)
                if test.settle_ms > 0:
                    time.sleep(test.settle_ms / 1000.0)
                if test.auto_mute:
                    self.runs.abort_loaded(generated_run.id)
                    self._loaded_runs.pop(test_id, None)
                else:
                    self._loaded_runs[test_id] = generated_run.id
            point = self.store.update_point(test_id, index, "READY")
            self.events.publish({"type": "test.point.updated", "data": point.model_dump(mode="json")})
            return point
        except Exception as exc:
            point = self.store.update_point(test_id, index, "FAILED", error=str(exc))
            self.store.update(test_id, state=TestSessionState.FAILED, error=str(exc))
            self.events.publish({"type": "test.point.updated", "data": point.model_dump(mode="json")})
            raise

    def record_measurement(self, test_id: str, index: int, measurement: dict[str, object]) -> PerformancePointRecord:
        point = self.store.update_point(test_id, index, "MEASURED", measurement=measurement)
        test = self.store.get(test_id)
        if all(item.state in {"MEASURED", "SKIPPED"} for item in self.store.points(test_id)):
            self.store.update(test_id, state=TestSessionState.COMPLETED, current_point=test.total_points)
            self.events.publish({"type": "test.completed", "data": self.store.get(test_id).model_dump(mode="json")})
        self.events.publish({"type": "test.point.updated", "data": point.model_dump(mode="json")})
        return point

    def export_json(self, test_id: str) -> dict[str, object]:
        return {"test": self.store.get(test_id).model_dump(mode="json"), "points": [item.model_dump(mode="json") for item in self.store.points(test_id)]}

    def export_csv(self, test_id: str) -> str:
        payload = self.export_json(test_id)
        output = io.StringIO()
        writer = csv.writer(output)
        writer.writerow(["test_id", "index", "state", "parameters", "measurement", "error", "environment_snapshot"])
        for point in payload["points"]:
            writer.writerow([test_id, point["index"], point["state"], json.dumps(point["parameters"], ensure_ascii=False), json.dumps(point["measurement"], ensure_ascii=False), point["error"], json.dumps(payload["test"]["environment"], ensure_ascii=False)])
        return output.getvalue()

    def _run_all(self, test_id: str, stop: threading.Event) -> None:
        test = self.store.get(test_id)
        try:
            for index in range(test.current_point, test.total_points):
                if stop.is_set():
                    return
                self.execute_point(test_id, index)
                if test.mode == "automatic":
                    self.store.update_point(test_id, index, "READY")
            if test.mode == "automatic":
                self.store.update(test_id, state=TestSessionState.COMPLETED, current_point=test.total_points)
                self.events.publish({"type": "test.completed", "data": self.store.get(test_id).model_dump(mode="json")})
        except Exception:
            return

    def _load_point(self, test: PerformanceTestRecord, point: PerformancePointRecord):
        previous = self._loaded_runs.pop(test.id, None)
        if previous:
            self.runs.abort_loaded(previous)
        base = self.rfdc.get(test.board_id)
        values = {item.channel: item.model_copy(deep=True) for item in base.channels}
        params = point.parameters
        selected = test.channels or [test.channel]
        for channel in selected:
            item = values[channel]
            if test.kind == TestKind.AMPLITUDE:
                if "dac_output_current_ma" in params: item.dac_output_current_ma = float(params["dac_output_current_ma"])
                if "data_amplitude" in params: item.data_amplitude = float(params["data_amplitude"])
            elif test.kind == TestKind.FREQUENCY:
                if "target_rf_hz" in params:
                    item.target_rf_hz = float(params["target_rf_hz"])
                    plan = host.rfdc_nco_plan_for_target(item.target_rf_hz)
                    item.nco_hz = float(plan["nco_hz"])
                    item.nyquist_zone = int(plan["nyquist_zone"])
                if "data_offset_hz" in params: item.data_offset_hz = float(params["data_offset_hz"])
            elif test.kind == TestKind.PHASE:
                if "data_phase_deg" in params: item.data_phase_deg = float(params["data_phase_deg"])
                if "nco_phase_deg" in params: item.nco_phase_deg = float(params["nco_phase_deg"])
        if test.dry_run:
            config = base.model_copy(update={"channels": list(values.values())})
        else:
            config = self.rfdc.apply(test.board_id, RfdcConfigApplyRequest(channels=list(values.values())))
        channels = []
        for channel in range(1, 9):
            item = values[channel]
            enabled = channel in selected
            amp = item.data_amplitude if enabled else 0.0
            channels.append(ManualChannel(channel=channel, enabled=enabled, waveform="dc-iq-cw", frequency_mhz=item.data_offset_hz / 1e6, phase_deg=item.data_phase_deg, amplitude=round(abs(amp) * 32767), data_amplitude=amp, duration_ns=1000))
        waveform = WaveformRequest(name=f"{test.name} point {point.index + 1}", mode="manual", record_duration_ns=10_000, manual_channels=channels)
        request = RunCreateRequest(
            # RFDC runtime settings were applied and read back by the PL above.
            # transaction when the waveform upload task is created.
            jobs=[BoardWaveformJob(board_id=test.board_id, waveform=waveform)],
            dry_run=test.dry_run,
            completion_mode="upload",
        )
        loaded = self.runs.create(request)
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            current = self.runs.store.get(loaded.id)
            if current and current.state.value in {"DONE", "FAULT", "ABORTED"}:
                if current.state.value != "DONE": raise RuntimeError(current.error or current.state.value)
                return current
            time.sleep(0.02)
        raise TimeoutError("waveform upload timed out")
