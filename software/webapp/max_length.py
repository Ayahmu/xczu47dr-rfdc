from __future__ import annotations

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

import dr47 as driver  # noqa: E402
# Compatibility local name for the constants/packet helpers used below.
host = driver
import waveform_tools  # noqa: E402

from .models import (  # noqa: E402
    MaxLengthTestCreateRequest,
    MaxLengthTestRecord,
    MaxLengthTestState,
    RfdcConfigApplyRequest,
)


def utc_now() -> str:
    return datetime.now(UTC).isoformat()


class MaxLengthStore:
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
                CREATE TABLE IF NOT EXISTS max_length_tests (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    board_id TEXT NOT NULL,
                    state TEXT NOT NULL,
                    progress REAL NOT NULL DEFAULT 0,
                    bytes_per_channel INTEGER NOT NULL DEFAULT 0,
                    physical_bytes INTEGER NOT NULL DEFAULT 0,
                    datagrams INTEGER NOT NULL DEFAULT 0,
                    pattern TEXT NOT NULL DEFAULT 'lowfreq-sine',
                    sine_freq_hz REAL NOT NULL DEFAULT 10.0,
                    sine_amplitude INTEGER NOT NULL DEFAULT 4096,
                    beats_per_datagram INTEGER NOT NULL DEFAULT 0,
                    auto_trigger INTEGER NOT NULL DEFAULT 1,
                    dry_run INTEGER NOT NULL DEFAULT 0,
                    upload_elapsed_s REAL NOT NULL DEFAULT 0,
                    upload_mbps REAL NOT NULL DEFAULT 0,
                    theoretical_duration_s REAL NOT NULL DEFAULT 0,
                    play_elapsed_s REAL NOT NULL DEFAULT 0,
                    read_counter INTEGER NOT NULL DEFAULT 0,
                    bad_instr_count INTEGER NOT NULL DEFAULT 0,
                    underflow_mask INTEGER NOT NULL DEFAULT 0,
                    error TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                """
            )

    def create(self, request: MaxLengthTestCreateRequest) -> MaxLengthTestRecord:
        test_id, timestamp = uuid.uuid4().hex[:12], utc_now()
        with self._connection() as connection:
            connection.execute(
                """INSERT INTO max_length_tests(
                    id, name, board_id, state, progress, bytes_per_channel,
                    physical_bytes, datagrams, pattern, sine_freq_hz, sine_amplitude,
                    beats_per_datagram, auto_trigger, dry_run, upload_elapsed_s,
                    upload_mbps, theoretical_duration_s, play_elapsed_s, read_counter,
                    bad_instr_count, underflow_mask, error, created_at, updated_at
                ) VALUES (?, ?, ?, 'PENDING', 0, ?, 0, 0, ?, ?, ?, ?, ?, ?, 0, 0, 0, 0, 0, 0, 0, '', ?, ?)""",
                (
                    test_id,
                    request.name,
                    request.board_id,
                    request.bytes_per_channel,
                    request.pattern,
                    request.sine_freq_hz,
                    request.sine_amplitude,
                    request.beats_per_datagram,
                    int(request.auto_trigger),
                    int(request.dry_run),
                    timestamp,
                    timestamp,
                ),
            )
        return self.get(test_id)

    def get(self, test_id: str) -> MaxLengthTestRecord:
        with self._connection() as connection:
            row = connection.execute("SELECT * FROM max_length_tests WHERE id=?", (test_id,)).fetchone()
        if row is None:
            raise KeyError(f"unknown max-length test {test_id}")
        return self._record(row)

    def list(self, limit: int = 100) -> list[MaxLengthTestRecord]:
        with self._connection() as connection:
            rows = connection.execute(
                "SELECT * FROM max_length_tests ORDER BY created_at DESC LIMIT ?", (limit,)
            ).fetchall()
        return [self._record(row) for row in rows]

    def update(self, test_id: str, **changes) -> MaxLengthTestRecord:
        allowed = {
            "state", "progress", "bytes_per_channel", "physical_bytes", "datagrams",
            "upload_elapsed_s", "upload_mbps", "theoretical_duration_s", "play_elapsed_s",
            "read_counter", "bad_instr_count", "underflow_mask", "error",
        }
        fields = [(key, value) for key, value in changes.items() if key in allowed]
        if fields:
            clause = ", ".join(f"{key}=?" for key, _ in fields)
            values = [value.value if isinstance(value, MaxLengthTestState) else value for _, value in fields]
            with self._connection() as connection:
                connection.execute(
                    f"UPDATE max_length_tests SET {clause}, updated_at=? WHERE id=?",
                    (*values, utc_now(), test_id),
                )
        return self.get(test_id)

    @staticmethod
    def _record(row: sqlite3.Row) -> MaxLengthTestRecord:
        return MaxLengthTestRecord(
            id=row["id"],
            name=row["name"],
            board_id=row["board_id"],
            state=row["state"],
            progress=float(row["progress"]),
            bytes_per_channel=int(row["bytes_per_channel"]),
            physical_bytes=int(row["physical_bytes"]),
            datagrams=int(row["datagrams"]),
            pattern=row["pattern"],
            sine_freq_hz=float(row["sine_freq_hz"]),
            sine_amplitude=int(row["sine_amplitude"]),
            beats_per_datagram=int(row["beats_per_datagram"]),
            auto_trigger=bool(row["auto_trigger"]),
            dry_run=bool(row["dry_run"]),
            upload_elapsed_s=float(row["upload_elapsed_s"]),
            upload_mbps=float(row["upload_mbps"]),
            theoretical_duration_s=float(row["theoretical_duration_s"]),
            play_elapsed_s=float(row["play_elapsed_s"]),
            read_counter=int(row["read_counter"]),
            bad_instr_count=int(row["bad_instr_count"]),
            underflow_mask=int(row["underflow_mask"]),
            error=row["error"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
        )


class MaxLengthService:
    def __init__(self, store: MaxLengthStore, management, boards, rfdc, events) -> None:
        self.store = store
        self.management = management
        self.boards = boards
        self.rfdc = rfdc
        self.events = events
        self._threads: dict[str, threading.Thread] = {}
        self._stop: dict[str, threading.Event] = {}
        self._lock = threading.RLock()

    def shutdown(self, timeout_s: float = 30.0) -> None:
        with self._lock:
            stops = tuple(self._stop.values())
            threads = tuple(self._threads.values())
        for stop in stops:
            stop.set()
        deadline = time.monotonic() + timeout_s
        for thread in threads:
            remaining = max(0.0, deadline - time.monotonic())
            thread.join(remaining)

    def create(self, request: MaxLengthTestCreateRequest) -> MaxLengthTestRecord:
        self.management.board(request.board_id)
        return self.store.create(request)

    def start(self, test_id: str) -> MaxLengthTestRecord:
        test = self.store.get(test_id)
        if test.state not in {MaxLengthTestState.PENDING, MaxLengthTestState.FAILED}:
            raise ValueError(f"test {test_id} is already {test.state.value}")
        stop = threading.Event()
        with self._lock:
            self._stop[test_id] = stop
            thread = threading.Thread(
                target=self._run,
                args=(test_id, stop),
                name=f"rfsoc-max-length-{test_id}",
                daemon=True,
            )
            self._threads[test_id] = thread
            thread.start()
        return self.store.get(test_id)

    def abort(self, test_id: str) -> MaxLengthTestRecord:
        stop = self._stop.get(test_id)
        if stop:
            stop.set()
        return self.store.update(test_id, state=MaxLengthTestState.ABORTED)

    def _run(self, test_id: str, stop: threading.Event) -> None:
        record = self.store.get(test_id)
        request = self._request_for(record)
        try:
            bytes_per_channel = request.bytes_per_channel or host.DDR_MAX_BYTES_PER_CHANNEL
            bytes_per_channel = host.require_beat_aligned(bytes_per_channel, "bytes_per_channel")
            physical_bytes = bytes_per_channel * host.DDR_INTERLEAVED_CHANNELS
            theoretical_duration_s = bytes_per_channel / (host.DAC_AXIS_HZ * host.BEAT_BYTES)
            if request.dry_run or self.boards.simulation:
                self.store.update(
                    test_id,
                    state=MaxLengthTestState.COMPLETED,
                    progress=1.0,
                    bytes_per_channel=bytes_per_channel,
                    physical_bytes=physical_bytes,
                    theoretical_duration_s=theoretical_duration_s,
                    play_elapsed_s=theoretical_duration_s,
                )
                self.events.publish({"type": "max_length.completed", "data": self.store.get(test_id).model_dump(mode="json")})
                return

            status = self.boards.status(record.board_id, refresh=True)
            if not status.online:
                raise RuntimeError(f"board {record.board_id} is not online")
            if not status.dac_mts_ready or status.dac_mts_failed:
                raise RuntimeError(f"board {record.board_id} DAC MTS is not ready; run one-click sync first")

            config = self.rfdc.get(record.board_id)
            self.rfdc.apply(
                record.board_id,
                RfdcConfigApplyRequest(channels=config.channels, channel_mask=0xFF),
            )

            board = self.management.board(record.board_id)
            controller = driver.Dr47Device(
                board.ip,
                port=board.port,
                timeout_s=10.0,
                udp_interface=board.udp_interface,
                udp_source_ip=board.udp_source_ip,
                retries=2,
            )
            try:
                self.store.update(test_id, state=MaxLengthTestState.UPLOADING, progress=0.0, bytes_per_channel=bytes_per_channel, physical_bytes=physical_bytes)
                upload_start = time.monotonic()
                sent_bytes = 0
                datagram_count = 0
                last_progress = 0.0
                for datagram in host.iter_max_length_udp_batches(
                    bytes_per_channel,
                    base_addr=host.DDR_BASE,
                    beats_per_datagram=request.beats_per_datagram or host.UDP_BULK_SAFE_MAX_BEATS,
                    pattern=request.pattern,
                    sine_freq_hz=request.sine_freq_hz,
                    sine_amplitude=request.sine_amplitude,
                ):
                    if stop.is_set():
                        raise RuntimeError("max-length test aborted during upload")
                    controller.transport.send(datagram)
                    datagram_count += 1
                    sent_bytes += len(datagram) - 24
                    if sent_bytes - last_progress >= 256 * 1024 * 1024 or sent_bytes == physical_bytes:
                        last_progress = sent_bytes
                        self.store.update(
                            test_id,
                            progress=min(1.0, sent_bytes / physical_bytes),
                            datagrams=datagram_count,
                            upload_elapsed_s=time.monotonic() - upload_start,
                            upload_mbps=(sent_bytes / max(time.monotonic() - upload_start, 1e-9)) / 1e6,
                        )
                        self.events.publish({"type": "max_length.progress", "data": self.store.get(test_id).model_dump(mode="json")})
                upload_elapsed = max(time.monotonic() - upload_start, 1e-9)
                self.store.update(
                    test_id,
                    progress=1.0,
                    datagrams=datagram_count,
                    upload_elapsed_s=upload_elapsed,
                    upload_mbps=(physical_bytes / upload_elapsed) / 1e6,
                    theoretical_duration_s=theoretical_duration_s,
                )

                if stop.is_set():
                    raise RuntimeError("max-length test aborted after upload")
                lengths = {channel: bytes_per_channel for channel in range(1, 9)}
                controller.send_instructions(
                    waveform_tools.build_play_commands(
                        loop=False,
                        auto_start=False,
                        channel_lengths=lengths,
                        channel_delays={channel: 0 for channel in range(1, 9)},
                        layout=host.DDR_LAYOUT_INTERLEAVED_512B,
                    )
                )
                self.store.update(test_id, state=MaxLengthTestState.PLAYING, progress=0.95)
                arm = controller.rfctrl2_arm(
                    int(test_id, 16) & 0xFFFFFFFF,
                    channel_mask=0xFF,
                    wait_response=True,
                )
                self._require_ok(arm, "ARM")
                prepared = self._wait_prepared(controller, stop)
                if not prepared:
                    raise RuntimeError("max-length ARM did not reach PREPARED")
                trigger = controller.rfctrl2_trigger(wait_response=True)
                self._require_ok(trigger, "TRIGGER")

                play_start = None
                read_start = 0
                read_end = 0
                bad_start = 0
                bad_end = 0
                underflow = 0
                timeout_s = max(30.0, theoretical_duration_s * 4.0 + 10.0)
                deadline = time.monotonic() + timeout_s
                while time.monotonic() < deadline:
                    if stop.is_set():
                        raise RuntimeError("max-length test aborted during playback")
                    response = controller.rfctrl2_status(wait_response=True)
                    decoded = host.parse_rfctrl2_status_payload(response)
                    if decoded["running"]:
                        if play_start is None:
                            play_start = time.monotonic()
                            read_start = int(decoded["play_ddr_read_counter"]) & 0xFFFFFFFF
                            bad_start = int(decoded["play_bad_instr_count"]) & 0xFFFFFFFF
                    elif play_start is not None:
                        read_end = int(decoded["play_ddr_read_counter"]) & 0xFFFFFFFF
                        bad_end = int(decoded["play_bad_instr_count"]) & 0xFFFFFFFF
                        underflow = int(decoded.get("underflow_mask", 0)) & 0xFFFF
                        self.store.update(
                            test_id,
                            state=MaxLengthTestState.COMPLETED,
                            progress=1.0,
                            play_elapsed_s=time.monotonic() - play_start,
                            read_counter=(read_end - read_start) & 0xFFFFFFFF,
                            bad_instr_count=(bad_end - bad_start) & 0xFFFFFFFF,
                            underflow_mask=underflow,
                        )
                        self.events.publish({"type": "max_length.completed", "data": self.store.get(test_id).model_dump(mode="json")})
                        return
                    time.sleep(0.02)
                raise TimeoutError("max-length playback did not complete within timeout")
            finally:
                try:
                    controller.rfctrl2_abort_mute(wait_response=True)
                except Exception:
                    pass
                controller.close()
        except Exception as exc:
            self.store.update(test_id, state=MaxLengthTestState.FAILED, error=str(exc))
            self.events.publish({"type": "max_length.failed", "data": self.store.get(test_id).model_dump(mode="json")})

    @staticmethod
    def _request_for(record: MaxLengthTestRecord) -> MaxLengthTestCreateRequest:
        return MaxLengthTestCreateRequest(
            name=record.name,
            board_id=record.board_id,
            bytes_per_channel=record.bytes_per_channel,
            pattern=record.pattern,
            sine_freq_hz=record.sine_freq_hz,
            sine_amplitude=record.sine_amplitude,
            beats_per_datagram=record.beats_per_datagram,
            auto_trigger=record.auto_trigger,
            dry_run=record.dry_run,
        )

    @staticmethod
    def _require_ok(response: dict, operation: str) -> None:
        if int(response.get("status", 1)) != host.RF2_STATUS_OK:
            raise RuntimeError(f"RFCTRL2 {operation} failed with status 0x{int(response.get('status', 1)):04X}")

    def _wait_prepared(self, controller: driver.Dr47Device, stop: threading.Event, timeout_s: float = 30.0) -> bool:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            if stop.is_set():
                return False
            response = controller.rfctrl2_status(wait_response=True)
            decoded = host.parse_rfctrl2_status_payload(response)
            if decoded["prepared"]:
                return True
            time.sleep(0.02)
        return False
