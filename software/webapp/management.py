from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import threading
import uuid
from contextlib import contextmanager
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Iterator

from .models import (
    ArtifactRecord,
    AuditEvent,
    BoardProfile,
    BoardUpdateRequest,
    DiscoveryResource,
    LeaseRecord,
    ProgramJob,
    BoardRfdcConfig,
    SerialLogLine,
    UserCreateRequest,
    UserRecord,
    UserRole,
    UserUpdateRequest,
)


def now() -> str:
    return datetime.now(UTC).isoformat()


class ManagementError(RuntimeError):
    pass


class PermissionError(ManagementError):
    pass


def hash_password(password: str, salt: bytes | None = None) -> str:
    salt = salt or secrets.token_bytes(16)
    iterations = 250_000
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations)
    return f"pbkdf2:{iterations}:{salt.hex()}:{digest.hex()}"


def verify_password(password: str, encoded: str) -> bool:
    try:
        scheme, iterations_text, salt_text, expected_text = encoded.split(":", 3)
        if scheme != "pbkdf2":
            return False
        actual = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt_text), int(iterations_text)).hex()
        return hmac.compare_digest(actual, expected_text)
    except (TypeError, ValueError):
        return False


class ManagementStore:
    """SQLite-backed identities, inventory, leases, diagnostics, and jobs."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=10)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA journal_mode = WAL")
        return connection

    @contextmanager
    def _transaction(self, immediate: bool = False) -> Iterator[sqlite3.Connection]:
        with self._lock:
            connection = self._connect()
            try:
                if immediate:
                    connection.execute("BEGIN IMMEDIATE")
                yield connection
                connection.commit()
            except Exception:
                connection.rollback()
                raise
            finally:
                connection.close()

    def _initialize(self) -> None:
        with self._transaction() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS users (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    username TEXT NOT NULL UNIQUE,
                    password_hash TEXT NOT NULL,
                    role TEXT NOT NULL CHECK(role IN ('admin', 'user')),
                    enabled INTEGER NOT NULL DEFAULT 1,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS sessions (
                    token TEXT PRIMARY KEY,
                    csrf_token TEXT NOT NULL,
                    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    expires_at TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS boards (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    model TEXT NOT NULL DEFAULT '',
                    role TEXT NOT NULL CHECK(role IN ('master', 'follower')),
                    ip TEXT NOT NULL,
                    port INTEGER NOT NULL,
                    mac TEXT NOT NULL DEFAULT '',
                    udp_interface TEXT NOT NULL,
                    udp_source_ip TEXT NOT NULL,
                    clock_source TEXT NOT NULL CHECK(clock_source IN ('onboard', 'master-10mhz')),
                    target_profile TEXT NOT NULL,
                    sync_group TEXT NOT NULL DEFAULT '',
                    jtag_cable_serial TEXT NOT NULL DEFAULT '',
                    serial_path TEXT NOT NULL DEFAULT '',
                    baud_rate INTEGER NOT NULL DEFAULT 115200,
                    serial_status TEXT NOT NULL DEFAULT 'missing',
                    serial_error TEXT NOT NULL DEFAULT '',
                    location TEXT NOT NULL DEFAULT '',
                    notes TEXT NOT NULL DEFAULT '',
                    enabled INTEGER NOT NULL DEFAULT 1,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS leases (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    board_id TEXT NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
                    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    status TEXT NOT NULL CHECK(status IN ('active', 'released', 'forced')),
                    starts_at TEXT NOT NULL,
                    released_at TEXT,
                    released_by INTEGER REFERENCES users(id)
                );
                CREATE UNIQUE INDEX IF NOT EXISTS one_active_lease_per_board
                    ON leases(board_id) WHERE status = 'active';
                CREATE TABLE IF NOT EXISTS discoveries (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL CHECK(kind IN ('jtag', 'serial')),
                    fingerprint TEXT NOT NULL UNIQUE,
                    label TEXT NOT NULL,
                    details_json TEXT NOT NULL,
                    first_seen_at TEXT NOT NULL,
                    last_seen_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS serial_logs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    board_id TEXT NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
                    line TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS serial_logs_board_index ON serial_logs(board_id, id DESC);
                CREATE TABLE IF NOT EXISTS artifacts (
                    id TEXT PRIMARY KEY,
                    label TEXT NOT NULL,
                    target_profile TEXT NOT NULL,
                    bit_name TEXT NOT NULL,
                    elf_name TEXT NOT NULL,
                    bit_path TEXT NOT NULL,
                    elf_path TEXT NOT NULL,
                    bit_sha256 TEXT NOT NULL,
                    elf_sha256 TEXT NOT NULL,
                    bit_size INTEGER NOT NULL,
                    elf_size INTEGER NOT NULL,
                    created_by INTEGER NOT NULL REFERENCES users(id),
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS program_jobs (
                    id TEXT PRIMARY KEY,
                    board_id TEXT NOT NULL REFERENCES boards(id),
                    artifact_id TEXT NOT NULL REFERENCES artifacts(id),
                    state TEXT NOT NULL,
                    progress REAL NOT NULL,
                    error TEXT NOT NULL DEFAULT '',
                    created_by INTEGER NOT NULL REFERENCES users(id),
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS program_logs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    job_id TEXT NOT NULL REFERENCES program_jobs(id) ON DELETE CASCADE,
                    line TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS audit_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    type TEXT NOT NULL,
                    message TEXT NOT NULL,
                    user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
                    board_id TEXT REFERENCES boards(id) ON DELETE SET NULL,
                    metadata_json TEXT NOT NULL DEFAULT '{}',
                    created_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS audit_events_created_index ON audit_events(created_at DESC);
                CREATE TABLE IF NOT EXISTS run_owners (
                    run_id TEXT PRIMARY KEY,
                    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE
                );
                CREATE TABLE IF NOT EXISTS rfdc_configs (
                    board_id TEXT PRIMARY KEY REFERENCES boards(id) ON DELETE CASCADE,
                    config_json TEXT NOT NULL,
                    revision INTEGER NOT NULL DEFAULT 0,
                    applied_at TEXT,
                    apply_status TEXT NOT NULL DEFAULT 'unknown',
                    apply_error TEXT NOT NULL DEFAULT '',
                    updated_at TEXT NOT NULL
                );
                """
            )
            self._seed(connection)

    def _seed(self, connection: sqlite3.Connection) -> None:
        if connection.execute("SELECT COUNT(*) AS count FROM users").fetchone()["count"] == 0:
            username = os.environ.get("RFSOC_WEB_ADMIN_USERNAME", "admin")
            password = os.environ.get("RFSOC_WEB_ADMIN_PASSWORD", "admin12345")
            connection.execute(
                "INSERT INTO users(username, password_hash, role, enabled, created_at) VALUES (?, ?, 'admin', 1, ?)",
                (username, hash_password(password), now()),
            )
        if connection.execute("SELECT COUNT(*) AS count FROM boards").fetchone()["count"] == 0:
            timestamp = now()
            rows = [
                ("board-a", "XCZU47DR A", "master", "192.168.1.128", "02:00:00:00:00:01", "onboard", "custom_xczu47dr"),
                ("board-b", "XCZU47DR B", "follower", "192.168.1.129", "02:00:00:00:00:02", "master-10mhz", "custom_xczu47dr_b"),
            ]
            for board_id, name, role, ip, mac, clock, target in rows:
                connection.execute(
                    """
                    INSERT INTO boards(
                        id, name, model, role, ip, port, mac, udp_interface, udp_source_ip,
                        clock_source, target_profile, sync_group, created_at, updated_at
                    ) VALUES (?, ?, 'XCZU47DR RFDC', ?, ?, 1234, ?, 'enp225s0f0', '192.168.1.10', ?, ?, 'pair-a-b', ?, ?)
                    """,
                    (board_id, name, role, ip, mac, clock, target, timestamp, timestamp),
                )

    @staticmethod
    def _user(row: sqlite3.Row | None) -> UserRecord | None:
        if row is None:
            return None
        return UserRecord(
            id=int(row["id"]), username=row["username"], role=UserRole(row["role"]),
            enabled=bool(row["enabled"]), created_at=row["created_at"],
        )

    @staticmethod
    def _lease(row: sqlite3.Row | None) -> LeaseRecord | None:
        if row is None or row["lease_id"] is None:
            return None
        return LeaseRecord(
            id=int(row["lease_id"]), board_id=row["lease_board_id"], user_id=int(row["lease_user_id"]),
            username=row["lease_username"], status=row["lease_status"], starts_at=row["lease_starts_at"],
            released_at=row["lease_released_at"],
        )

    def _board(self, row: sqlite3.Row) -> BoardProfile:
        return BoardProfile(
            id=row["id"], name=row["name"], model=row["model"], role=row["role"], ip=row["ip"], port=int(row["port"]),
            mac=row["mac"], udp_interface=row["udp_interface"], udp_source_ip=row["udp_source_ip"],
            clock_source=row["clock_source"], target_profile=row["target_profile"], sync_group=row["sync_group"],
            jtag_cable_serial=row["jtag_cable_serial"], serial_path=row["serial_path"], baud_rate=int(row["baud_rate"]),
            serial_status=row["serial_status"], serial_error=row["serial_error"], location=row["location"], notes=row["notes"],
            enabled=bool(row["enabled"]), lease=self._lease(row),
        )

    def _board_query(self) -> str:
        return """
            SELECT boards.*, leases.id AS lease_id, leases.board_id AS lease_board_id,
                   leases.user_id AS lease_user_id, leases.status AS lease_status,
                   leases.starts_at AS lease_starts_at, leases.released_at AS lease_released_at,
                   users.username AS lease_username
            FROM boards
            LEFT JOIN leases ON leases.board_id = boards.id AND leases.status = 'active'
            LEFT JOIN users ON users.id = leases.user_id
        """

    def list_boards(self) -> list[BoardProfile]:
        with self._transaction() as connection:
            rows = connection.execute(self._board_query() + " ORDER BY boards.name COLLATE NOCASE").fetchall()
        return [self._board(row) for row in rows]

    def board(self, board_id: str) -> BoardProfile:
        with self._transaction() as connection:
            row = connection.execute(self._board_query() + " WHERE boards.id = ?", (board_id,)).fetchone()
        if row is None:
            raise KeyError(f"unknown board {board_id}")
        return self._board(row)

    def add_board(self, request: BoardUpdateRequest) -> BoardProfile:
        board_id = uuid.uuid4().hex[:12]
        self._write_board(board_id, request, create=True)
        return self.board(board_id)

    def update_board(self, board_id: str, request: BoardUpdateRequest) -> BoardProfile:
        self._write_board(board_id, request, create=False)
        return self.board(board_id)

    def _write_board(self, board_id: str, request: BoardUpdateRequest, create: bool) -> None:
        values = request.model_dump()
        timestamp = now()
        with self._transaction(immediate=True) as connection:
            if not create and connection.execute("SELECT 1 FROM boards WHERE id = ?", (board_id,)).fetchone() is None:
                raise KeyError(f"unknown board {board_id}")
            if values["serial_path"]:
                conflict = connection.execute("SELECT id FROM boards WHERE serial_path = ? AND id != ?", (values["serial_path"], board_id)).fetchone()
                if conflict:
                    raise ManagementError("serial port is already bound to another board")
            if create:
                connection.execute(
                    """
                    INSERT INTO boards(id, name, model, role, ip, port, mac, udp_interface, udp_source_ip, clock_source,
                        target_profile, sync_group, jtag_cable_serial, serial_path, baud_rate, location, notes, enabled, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (board_id, values["name"], values["model"], values["role"], values["ip"], values["port"], values["mac"],
                     values["udp_interface"], values["udp_source_ip"], values["clock_source"], values["target_profile"], values["sync_group"],
                     values["jtag_cable_serial"], values["serial_path"], values["baud_rate"], values["location"], values["notes"],
                     int(values["enabled"]), timestamp, timestamp),
                )
            else:
                connection.execute(
                    """
                    UPDATE boards SET name=?, model=?, role=?, ip=?, port=?, mac=?, udp_interface=?, udp_source_ip=?, clock_source=?,
                        target_profile=?, sync_group=?, jtag_cable_serial=?, serial_path=?, baud_rate=?, location=?, notes=?, enabled=?, updated_at=?
                    WHERE id=?
                    """,
                    (values["name"], values["model"], values["role"], values["ip"], values["port"], values["mac"],
                     values["udp_interface"], values["udp_source_ip"], values["clock_source"], values["target_profile"], values["sync_group"],
                     values["jtag_cable_serial"], values["serial_path"], values["baud_rate"], values["location"], values["notes"],
                     int(values["enabled"]), timestamp, board_id),
                )

    def authenticate(self, username: str, password: str) -> UserRecord | None:
        with self._transaction() as connection:
            row = connection.execute("SELECT * FROM users WHERE username = ? AND enabled = 1", (username,)).fetchone()
        if row is None or not verify_password(password, row["password_hash"]):
            return None
        return self._user(row)

    def create_session(self, user: UserRecord) -> tuple[str, str]:
        token = secrets.token_urlsafe(32)
        csrf = secrets.token_urlsafe(24)
        expires = (datetime.now(UTC) + timedelta(days=14)).isoformat()
        with self._transaction() as connection:
            connection.execute("INSERT INTO sessions(token, csrf_token, user_id, expires_at, created_at) VALUES (?, ?, ?, ?, ?)",
                               (token, csrf, user.id, expires, now()))
        return token, csrf

    def session_user(self, token: str | None) -> tuple[UserRecord | None, str | None]:
        if not token:
            return None, None
        with self._transaction() as connection:
            row = connection.execute(
                """SELECT users.*, sessions.csrf_token FROM sessions JOIN users ON users.id=sessions.user_id
                   WHERE sessions.token=? AND sessions.expires_at > ? AND users.enabled=1""", (token, now())
            ).fetchone()
        return self._user(row), row["csrf_token"] if row else None

    def delete_session(self, token: str | None) -> None:
        if not token:
            return
        with self._transaction() as connection:
            connection.execute("DELETE FROM sessions WHERE token = ?", (token,))

    def list_users(self) -> list[UserRecord]:
        with self._transaction() as connection:
            rows = connection.execute("SELECT id, username, role, enabled, created_at FROM users ORDER BY username COLLATE NOCASE").fetchall()
        return [self._user(row) for row in rows if self._user(row) is not None]

    def create_user(self, request: UserCreateRequest) -> UserRecord:
        with self._transaction(immediate=True) as connection:
            try:
                cursor = connection.execute("INSERT INTO users(username, password_hash, role, enabled, created_at) VALUES (?, ?, ?, ?, ?)",
                                            (request.username, hash_password(request.password), request.role.value, int(request.enabled), now()))
            except sqlite3.IntegrityError as exc:
                raise ManagementError("username already exists") from exc
            row = connection.execute("SELECT id, username, role, enabled, created_at FROM users WHERE id=?", (cursor.lastrowid,)).fetchone()
        return self._user(row)  # type: ignore[return-value]

    def update_user(self, user_id: int, request: UserUpdateRequest) -> UserRecord:
        with self._transaction(immediate=True) as connection:
            current = connection.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
            if current is None:
                raise KeyError("unknown user")
            if request.password:
                connection.execute("UPDATE users SET password_hash=?, role=?, enabled=? WHERE id=?",
                                   (hash_password(request.password), request.role.value, int(request.enabled), user_id))
            else:
                connection.execute("UPDATE users SET role=?, enabled=? WHERE id=?", (request.role.value, int(request.enabled), user_id))
            if not request.enabled:
                connection.execute("DELETE FROM sessions WHERE user_id=?", (user_id,))
            row = connection.execute("SELECT id, username, role, enabled, created_at FROM users WHERE id=?", (user_id,)).fetchone()
        return self._user(row)  # type: ignore[return-value]

    def active_lease(self, board_id: str) -> LeaseRecord | None:
        with self._transaction() as connection:
            row = connection.execute(
                """SELECT leases.id AS lease_id, leases.board_id AS lease_board_id, leases.user_id AS lease_user_id,
                          leases.status AS lease_status, leases.starts_at AS lease_starts_at, leases.released_at AS lease_released_at,
                          users.username AS lease_username FROM leases JOIN users ON users.id=leases.user_id
                   WHERE leases.board_id=? AND leases.status='active'""", (board_id,)
            ).fetchone()
        return self._lease(row)

    def lease_board(self, board_id: str, user: UserRecord) -> BoardProfile:
        with self._transaction(immediate=True) as connection:
            board = connection.execute("SELECT enabled FROM boards WHERE id=?", (board_id,)).fetchone()
            if board is None:
                raise KeyError(f"unknown board {board_id}")
            if not board["enabled"]:
                raise ManagementError("board is disabled")
            lease = connection.execute("SELECT 1 FROM leases WHERE board_id=? AND status='active'", (board_id,)).fetchone()
            if lease:
                raise ManagementError("board is already leased")
            connection.execute("INSERT INTO leases(board_id, user_id, status, starts_at) VALUES (?, ?, 'active', ?)",
                               (board_id, user.id, now()))
        self.add_audit("lease.acquired", f"{user.username} acquired board", user.id, board_id)
        return self.board(board_id)

    def release_board(self, board_id: str, actor: UserRecord, force: bool = False) -> BoardProfile:
        with self._transaction(immediate=True) as connection:
            row = connection.execute("SELECT * FROM leases WHERE board_id=? AND status='active'", (board_id,)).fetchone()
            if row is None:
                raise ManagementError("board is not leased")
            if row["user_id"] != actor.id and not force:
                raise PermissionError("only the lease owner may release this board")
            status = "forced" if force else "released"
            connection.execute("UPDATE leases SET status=?, released_at=?, released_by=? WHERE id=?",
                               (status, now(), actor.id, row["id"]))
        self.add_audit("lease.forced" if force else "lease.released", f"{actor.username} released board", actor.id, board_id)
        return self.board(board_id)

    def require_lease(self, user: UserRecord, board_id: str) -> None:
        lease = self.active_lease(board_id)
        if lease is None or lease.user_id != user.id:
            raise PermissionError("an active lease is required for live board control")

    def set_run_owner(self, run_id: str, user: UserRecord) -> None:
        with self._transaction() as connection:
            connection.execute("INSERT OR REPLACE INTO run_owners(run_id, user_id) VALUES (?, ?)", (run_id, user.id))

    def can_manage_run(self, run_id: str, user: UserRecord) -> bool:
        if user.role == UserRole.ADMIN:
            return True
        with self._transaction() as connection:
            row = connection.execute("SELECT user_id FROM run_owners WHERE run_id=?", (run_id,)).fetchone()
        return row is not None and row["user_id"] == user.id

    def load_rfdc_config(self, board_id: str) -> BoardRfdcConfig | None:
        with self._transaction() as connection:
            row = connection.execute("SELECT * FROM rfdc_configs WHERE board_id=?", (board_id,)).fetchone()
        if row is None:
            return None
        config = BoardRfdcConfig.model_validate_json(row["config_json"])
        return config.model_copy(update={
            "board_id": board_id,
            "revision": int(row["revision"]),
            "applied_at": row["applied_at"],
            "apply_status": row["apply_status"],
            "apply_error": row["apply_error"],
        })

    def save_rfdc_config(self, config: BoardRfdcConfig) -> BoardRfdcConfig:
        with self._transaction(immediate=True) as connection:
            connection.execute(
                """INSERT INTO rfdc_configs(board_id, config_json, revision, applied_at, apply_status, apply_error, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(board_id) DO UPDATE SET config_json=excluded.config_json, revision=excluded.revision,
                     applied_at=excluded.applied_at, apply_status=excluded.apply_status, apply_error=excluded.apply_error,
                     updated_at=excluded.updated_at""",
                (config.board_id, config.model_dump_json(), config.revision, config.applied_at, config.apply_status,
                 config.apply_error, now()),
            )
        return config

    def set_serial_binding(self, board_id: str, path: str, baud_rate: int) -> BoardProfile:
        with self._transaction(immediate=True) as connection:
            if connection.execute("SELECT 1 FROM boards WHERE id=?", (board_id,)).fetchone() is None:
                raise KeyError(f"unknown board {board_id}")
            conflict = connection.execute("SELECT id FROM boards WHERE serial_path=? AND id != ?", (path, board_id)).fetchone()
            if conflict:
                raise ManagementError("serial port is already bound to another board")
            connection.execute("UPDATE boards SET serial_path=?, baud_rate=?, serial_status='connecting', serial_error='', updated_at=? WHERE id=?",
                               (path, baud_rate, now(), board_id))
        return self.board(board_id)

    def update_serial_state(self, board_id: str, state: str, error: str = "") -> None:
        with self._transaction() as connection:
            connection.execute("UPDATE boards SET serial_status=?, serial_error=?, updated_at=? WHERE id=?", (state, error, now(), board_id))

    def add_serial_log(self, board_id: str, line: str, limit: int) -> SerialLogLine:
        item = SerialLogLine(line=line, created_at=now())
        with self._transaction() as connection:
            connection.execute("INSERT INTO serial_logs(board_id, line, created_at) VALUES (?, ?, ?)", (board_id, item.line, item.created_at))
            connection.execute("""DELETE FROM serial_logs WHERE board_id=? AND id NOT IN
                               (SELECT id FROM serial_logs WHERE board_id=? ORDER BY id DESC LIMIT ?)""", (board_id, board_id, limit))
        return item

    def serial_logs(self, board_id: str, limit: int = 5000) -> list[SerialLogLine]:
        with self._transaction() as connection:
            rows = connection.execute("SELECT line, created_at FROM serial_logs WHERE board_id=? ORDER BY id DESC LIMIT ?", (board_id, limit)).fetchall()
        return [SerialLogLine(line=row["line"], created_at=row["created_at"]) for row in reversed(rows)]

    def upsert_discovery(self, kind: str, fingerprint: str, label: str, details: dict[str, object]) -> DiscoveryResource:
        timestamp = now()
        with self._transaction() as connection:
            existing = connection.execute("SELECT id, first_seen_at FROM discoveries WHERE fingerprint=?", (fingerprint,)).fetchone()
            if existing:
                connection.execute("UPDATE discoveries SET label=?, details_json=?, last_seen_at=? WHERE id=?",
                                   (label, json.dumps(details), timestamp, existing["id"]))
            else:
                cursor = connection.execute("INSERT INTO discoveries(kind, fingerprint, label, details_json, first_seen_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?)",
                                            (kind, fingerprint, label, json.dumps(details), timestamp, timestamp))
                existing = {"id": cursor.lastrowid, "first_seen_at": timestamp}
            cable_serial = str(details.get("cable_serial", ""))
            serial_path = str(details.get("path") or details.get("stable_path", ""))
            board = connection.execute(
                """SELECT id FROM boards
                   WHERE (? != '' AND jtag_cable_serial = ?)
                      OR (? != '' AND serial_path = ?)""",
                (cable_serial, cable_serial, serial_path, serial_path),
            ).fetchone()
            return DiscoveryResource(id=int(existing["id"]), kind=kind, fingerprint=fingerprint, label=label, details=details,
                                     state="registered" if board else "pending", board_id=board["id"] if board else None,
                                     first_seen_at=existing["first_seen_at"], last_seen_at=timestamp)

    def prune_discoveries(self, kind: str, fingerprints: set[str]) -> None:
        """Remove stale entries after a successful complete inventory scan."""
        with self._transaction() as connection:
            if fingerprints:
                placeholders = ",".join("?" for _ in fingerprints)
                connection.execute(
                    f"DELETE FROM discoveries WHERE kind=? AND fingerprint NOT IN ({placeholders})",
                    (kind, *sorted(fingerprints)),
                )
            else:
                connection.execute("DELETE FROM discoveries WHERE kind=?", (kind,))

    def discoveries(self) -> list[DiscoveryResource]:
        boards = self.list_boards()
        by_jtag = {board.jtag_cable_serial: board.id for board in boards if board.jtag_cable_serial}
        by_serial = {board.serial_path: board.id for board in boards if board.serial_path}
        with self._transaction() as connection:
            rows = connection.execute("SELECT * FROM discoveries ORDER BY last_seen_at DESC").fetchall()
        result: list[DiscoveryResource] = []
        for row in rows:
            details = json.loads(row["details_json"])
            serial_path = str(details.get("path") or details.get("stable_path", ""))
            board_id = by_jtag.get(str(details.get("cable_serial", ""))) or by_serial.get(serial_path)
            result.append(DiscoveryResource(id=row["id"], kind=row["kind"], fingerprint=row["fingerprint"], label=row["label"],
                                            details=details, state="registered" if board_id else "pending", board_id=board_id,
                                            first_seen_at=row["first_seen_at"], last_seen_at=row["last_seen_at"]))
        return result

    def add_artifact(self, *, label: str, target_profile: str, bit_name: str, elf_name: str, bit_path: Path, elf_path: Path,
                     bit_sha256: str, elf_sha256: str, bit_size: int, elf_size: int, user: UserRecord) -> ArtifactRecord:
        artifact_id = uuid.uuid4().hex[:12]
        timestamp = now()
        with self._transaction() as connection:
            connection.execute(
                """INSERT INTO artifacts(id, label, target_profile, bit_name, elf_name, bit_path, elf_path, bit_sha256, elf_sha256,
                   bit_size, elf_size, created_by, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (artifact_id, label, target_profile, bit_name, elf_name, str(bit_path), str(elf_path), bit_sha256, elf_sha256,
                 bit_size, elf_size, user.id, timestamp),
            )
        return self.artifact(artifact_id)

    def artifact(self, artifact_id: str) -> ArtifactRecord:
        with self._transaction() as connection:
            row = connection.execute("""SELECT artifacts.*, users.username FROM artifacts JOIN users ON users.id=artifacts.created_by
                                      WHERE artifacts.id=?""", (artifact_id,)).fetchone()
        if row is None:
            raise KeyError("unknown artifact")
        return ArtifactRecord(id=row["id"], label=row["label"], target_profile=row["target_profile"], bit_name=row["bit_name"],
                              elf_name=row["elf_name"], bit_sha256=row["bit_sha256"], elf_sha256=row["elf_sha256"],
                              bit_size=row["bit_size"], elf_size=row["elf_size"], created_at=row["created_at"], created_by=row["username"])

    def artifact_paths(self, artifact_id: str) -> tuple[Path, Path]:
        with self._transaction() as connection:
            row = connection.execute("SELECT bit_path, elf_path FROM artifacts WHERE id=?", (artifact_id,)).fetchone()
        if row is None:
            raise KeyError("unknown artifact")
        return Path(row["bit_path"]), Path(row["elf_path"])

    def list_artifacts(self) -> list[ArtifactRecord]:
        with self._transaction() as connection:
            rows = connection.execute("""SELECT artifacts.*, users.username FROM artifacts JOIN users ON users.id=artifacts.created_by
                                      ORDER BY artifacts.created_at DESC""").fetchall()
        return [ArtifactRecord(id=row["id"], label=row["label"], target_profile=row["target_profile"], bit_name=row["bit_name"],
                               elf_name=row["elf_name"], bit_sha256=row["bit_sha256"], elf_sha256=row["elf_sha256"],
                               bit_size=row["bit_size"], elf_size=row["elf_size"], created_at=row["created_at"], created_by=row["username"])
                for row in rows]

    def latest_successful_artifact(self, board_id: str) -> ArtifactRecord | None:
        with self._transaction() as connection:
            row = connection.execute(
                """SELECT artifact_id FROM program_jobs
                   WHERE board_id=? AND state='SUCCEEDED'
                   ORDER BY updated_at DESC LIMIT 1""",
                (board_id,),
            ).fetchone()
        return self.artifact(row["artifact_id"]) if row else None

    def create_program_job(self, board_id: str, artifact_id: str, user: UserRecord) -> ProgramJob:
        job_id, timestamp = uuid.uuid4().hex[:12], now()
        with self._transaction(immediate=True) as connection:
            active = connection.execute(
                "SELECT id FROM program_jobs WHERE board_id=? AND state IN ('QUEUED', 'PREFLIGHT', 'RUNNING')",
                (board_id,),
            ).fetchone()
            if active:
                raise ManagementError(f"programming job {active['id']} already owns board {board_id}")
            connection.execute("INSERT INTO program_jobs(id, board_id, artifact_id, state, progress, created_by, created_at, updated_at) VALUES (?, ?, ?, 'QUEUED', 0, ?, ?, ?)",
                               (job_id, board_id, artifact_id, user.id, timestamp, timestamp))
        return self.program_job(job_id)

    def update_program_job(self, job_id: str, state: str, progress: float, error: str = "") -> ProgramJob:
        with self._transaction() as connection:
            connection.execute("UPDATE program_jobs SET state=?, progress=?, error=?, updated_at=? WHERE id=?", (state, progress, error, now(), job_id))
        return self.program_job(job_id)

    def program_job(self, job_id: str) -> ProgramJob:
        with self._transaction() as connection:
            row = connection.execute("""SELECT program_jobs.*, users.username FROM program_jobs JOIN users ON users.id=program_jobs.created_by
                                      WHERE program_jobs.id=?""", (job_id,)).fetchone()
        if row is None:
            raise KeyError("unknown programming job")
        return ProgramJob(id=row["id"], board_id=row["board_id"], artifact_id=row["artifact_id"], state=row["state"], progress=row["progress"],
                          created_at=row["created_at"], updated_at=row["updated_at"], created_by=row["username"], error=row["error"])

    def list_program_jobs(self, limit: int = 100) -> list[ProgramJob]:
        with self._transaction() as connection:
            rows = connection.execute("""SELECT program_jobs.*, users.username FROM program_jobs JOIN users ON users.id=program_jobs.created_by
                                      ORDER BY program_jobs.created_at DESC LIMIT ?""", (limit,)).fetchall()
        return [ProgramJob(id=row["id"], board_id=row["board_id"], artifact_id=row["artifact_id"], state=row["state"], progress=row["progress"],
                           created_at=row["created_at"], updated_at=row["updated_at"], created_by=row["username"], error=row["error"])
                for row in rows]

    def add_program_log(self, job_id: str, line: str) -> None:
        with self._transaction() as connection:
            connection.execute("INSERT INTO program_logs(job_id, line, created_at) VALUES (?, ?, ?)", (job_id, line.rstrip(), now()))

    def program_logs(self, job_id: str) -> list[SerialLogLine]:
        with self._transaction() as connection:
            rows = connection.execute("SELECT line, created_at FROM program_logs WHERE job_id=? ORDER BY id", (job_id,)).fetchall()
        return [SerialLogLine(line=row["line"], created_at=row["created_at"]) for row in rows]

    def add_audit(self, event_type: str, message: str, user_id: int | None = None, board_id: str | None = None, metadata: dict[str, object] | None = None) -> None:
        with self._transaction() as connection:
            connection.execute("INSERT INTO audit_events(type, message, user_id, board_id, metadata_json, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                               (event_type, message, user_id, board_id, json.dumps(metadata or {}), now()))

    def audit_events(self, limit: int = 100) -> list[AuditEvent]:
        with self._transaction() as connection:
            rows = connection.execute("""SELECT audit_events.*, users.username FROM audit_events LEFT JOIN users ON users.id=audit_events.user_id
                                      ORDER BY audit_events.id DESC LIMIT ?""", (limit,)).fetchall()
        return [AuditEvent(id=row["id"], type=row["type"], message=row["message"], username=row["username"], board_id=row["board_id"],
                           created_at=row["created_at"], metadata=json.loads(row["metadata_json"])) for row in rows]
