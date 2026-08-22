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
    PhaseCalibrationRecord,
    PhaseCalibrationRequest,
    SerialLogLine,
    UserCreateRequest,
    UserRecord,
    UserRole,
    UserUpdateRequest,
)
from .network import auto_fpga_link_profile, ip_pool_for_interface


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
                    ip TEXT NOT NULL,
                    port INTEGER NOT NULL,
                    mac TEXT NOT NULL DEFAULT '',
                    udp_interface TEXT NOT NULL,
                    udp_source_ip TEXT NOT NULL,
                    clock_source TEXT NOT NULL CHECK(clock_source IN ('onboard')),
                    target_profile TEXT NOT NULL,
                    jtag_cable_serial TEXT NOT NULL DEFAULT '',
                    serial_path TEXT NOT NULL DEFAULT '',
                    baud_rate INTEGER NOT NULL DEFAULT 115200,
                    serial_status TEXT NOT NULL DEFAULT 'missing',
                    serial_error TEXT NOT NULL DEFAULT '',
                    location TEXT NOT NULL DEFAULT '',
                    notes TEXT NOT NULL DEFAULT '',
                    last_seen_at TEXT NOT NULL DEFAULT '',
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
                CREATE TABLE IF NOT EXISTS phase_calibrations (
                    device_uid TEXT NOT NULL,
                    frequency_hz INTEGER NOT NULL CHECK(frequency_hz >= 0 AND frequency_hz <= 6400000000),
                    channel INTEGER NOT NULL CHECK(channel BETWEEN 1 AND 8),
                    phase_deg REAL NOT NULL CHECK(phase_deg >= -3600.0 AND phase_deg <= 3600.0),
                    updated_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY(device_uid, frequency_hz, channel)
                );
                CREATE INDEX IF NOT EXISTS phase_calibrations_device_index
                    ON phase_calibrations(device_uid, frequency_hz, channel);
                """
            )
            # Keep the database file backwards compatible with installations
            # created before network identity was split into desired/active
            # values. SQLite has no portable IF NOT EXISTS form for columns.
            self._ensure_column(connection, "boards", "bootstrap_ip", "TEXT NOT NULL DEFAULT '192.168.254.254'")
            self._ensure_column(connection, "boards", "desired_ip", "TEXT NOT NULL DEFAULT ''")
            self._ensure_column(connection, "boards", "active_ip", "TEXT NOT NULL DEFAULT ''")
            self._ensure_column(connection, "boards", "desired_mac", "TEXT NOT NULL DEFAULT ''")
            self._ensure_column(connection, "boards", "active_mac", "TEXT NOT NULL DEFAULT ''")
            self._ensure_column(connection, "boards", "device_uid", "TEXT NOT NULL DEFAULT ''")
            self._ensure_column(connection, "boards", "network_revision", "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(connection, "boards", "network_apply_status", "TEXT NOT NULL DEFAULT 'unknown'")
            self._ensure_column(connection, "boards", "network_apply_error", "TEXT NOT NULL DEFAULT ''")
            self._ensure_column(connection, "boards", "last_seen_at", "TEXT NOT NULL DEFAULT ''")
            self._migrate_single_board_inventory_schema(connection)
            connection.execute("UPDATE boards SET clock_source='onboard' WHERE clock_source!='onboard'")
            connection.execute(
                """UPDATE boards
                   SET desired_ip = CASE WHEN desired_ip = '' THEN ip ELSE desired_ip END,
                       active_ip = CASE WHEN active_ip = '' THEN ip ELSE active_ip END,
                       desired_mac = CASE WHEN desired_mac = '' THEN mac ELSE desired_mac END,
                       active_mac = CASE WHEN active_mac = '' THEN mac ELSE active_mac END
                   WHERE desired_ip = '' OR active_ip = '' OR desired_mac = '' OR active_mac = ''"""
            )
            self._cleanup_legacy_inventory(connection)
            self._repair_auto_profiles(connection)
            self._seed(connection)

    @staticmethod
    def _ensure_column(connection: sqlite3.Connection, table: str, column: str, definition: str) -> None:
        columns = {row["name"] for row in connection.execute(f"PRAGMA table_info({table})").fetchall()}
        if column not in columns:
            connection.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")

    @staticmethod
    def _migrate_single_board_inventory_schema(connection: sqlite3.Connection) -> None:
        columns = {row["name"] for row in connection.execute("PRAGMA table_info(boards)").fetchall()}
        legacy_columns = {"role", "sync_group"} & columns
        if not legacy_columns:
            return
        target_columns = [
            "id", "name", "model", "ip", "port", "mac", "udp_interface", "udp_source_ip",
            "clock_source", "target_profile", "jtag_cable_serial", "serial_path", "baud_rate",
            "serial_status", "serial_error", "location", "notes", "last_seen_at", "enabled",
            "created_at", "updated_at", "bootstrap_ip", "desired_ip", "active_ip", "desired_mac",
            "active_mac", "device_uid", "network_revision", "network_apply_status",
            "network_apply_error",
        ]
        defaults = {
            "id": "lower(hex(randomblob(8)))",
            "name": "'FPGA'",
            "model": "'XCZU47DR RFDC'",
            "ip": "'192.168.1.128'",
            "port": "1234",
            "mac": "''",
            "udp_interface": "'enp225s0f0'",
            "udp_source_ip": "'192.168.1.10'",
            "clock_source": "'onboard'",
            "target_profile": "'custom_xczu47dr'",
            "jtag_cable_serial": "''",
            "serial_path": "''",
            "baud_rate": "115200",
            "serial_status": "'missing'",
            "serial_error": "''",
            "location": "''",
            "notes": "''",
            "last_seen_at": "''",
            "enabled": "1",
            "created_at": f"'{now()}'",
            "updated_at": f"'{now()}'",
            "bootstrap_ip": "'192.168.254.254'",
            "desired_ip": "''",
            "active_ip": "''",
            "desired_mac": "''",
            "active_mac": "''",
            "device_uid": "''",
            "network_revision": "0",
            "network_apply_status": "'unknown'",
            "network_apply_error": "''",
        }
        connection.executescript(
            """
            DROP TABLE IF EXISTS boards_single_board_migration;
            CREATE TABLE boards_single_board_migration (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                model TEXT NOT NULL DEFAULT '',
                ip TEXT NOT NULL,
                port INTEGER NOT NULL,
                mac TEXT NOT NULL DEFAULT '',
                udp_interface TEXT NOT NULL,
                udp_source_ip TEXT NOT NULL,
                clock_source TEXT NOT NULL CHECK(clock_source IN ('onboard')),
                target_profile TEXT NOT NULL,
                jtag_cable_serial TEXT NOT NULL DEFAULT '',
                serial_path TEXT NOT NULL DEFAULT '',
                baud_rate INTEGER NOT NULL DEFAULT 115200,
                serial_status TEXT NOT NULL DEFAULT 'missing',
                serial_error TEXT NOT NULL DEFAULT '',
                location TEXT NOT NULL DEFAULT '',
                notes TEXT NOT NULL DEFAULT '',
                last_seen_at TEXT NOT NULL DEFAULT '',
                enabled INTEGER NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                bootstrap_ip TEXT NOT NULL DEFAULT '192.168.254.254',
                desired_ip TEXT NOT NULL DEFAULT '',
                active_ip TEXT NOT NULL DEFAULT '',
                desired_mac TEXT NOT NULL DEFAULT '',
                active_mac TEXT NOT NULL DEFAULT '',
                device_uid TEXT NOT NULL DEFAULT '',
                network_revision INTEGER NOT NULL DEFAULT 0,
                network_apply_status TEXT NOT NULL DEFAULT 'unknown',
                network_apply_error TEXT NOT NULL DEFAULT ''
            );
            """
        )
        select_list = [column if column in columns else defaults[column] for column in target_columns]
        connection.execute(
            f"INSERT INTO boards_single_board_migration({', '.join(target_columns)}) "
            f"SELECT {', '.join(select_list)} FROM boards"
        )
        connection.executescript(
            """
            DROP TABLE boards;
            ALTER TABLE boards_single_board_migration RENAME TO boards;
            """
        )

    def _seed(self, connection: sqlite3.Connection) -> None:
        if connection.execute("SELECT COUNT(*) AS count FROM users").fetchone()["count"] == 0:
            username = os.environ.get("RFSOC_WEB_ADMIN_USERNAME", "admin")
            password = os.environ.get("RFSOC_WEB_ADMIN_PASSWORD", "admin12345")
            connection.execute(
                "INSERT INTO users(username, password_hash, role, enabled, created_at) VALUES (?, ?, 'admin', 1, ?)",
                (username, hash_password(password), now()),
            )
        if (
            os.environ.get("RFSOC_WEB_SIMULATION", "0") == "1"
            and os.environ.get("RFSOC_WEB_SEED_SIMULATION_BOARDS", "0") == "1"
            and connection.execute("SELECT COUNT(*) AS count FROM boards").fetchone()["count"] == 0
        ):
            timestamp = now()
            rows = [
                ("board-a", "XCZU47DR A", "enp225s0f0", "custom_xczu47dr"),
                ("board-b", "XCZU47DR B", "enp225s0f1", "custom_xczu47dr_slave"),
            ]
            for board_id, name, udp_interface, target_profile in rows:
                profile = auto_fpga_link_profile(udp_interface) or {}
                ip = profile.get("target_ip", "192.168.1.128")
                connection.execute(
                    """
                    INSERT INTO boards(
                        id, name, model, ip, port, mac, bootstrap_ip, desired_ip, active_ip,
                        desired_mac, active_mac, device_uid, network_revision, network_apply_status,
                        udp_interface, udp_source_ip, clock_source,
                        target_profile, last_seen_at, created_at, updated_at
                    ) VALUES (?, ?, 'XCZU47DR RFDC', ?, 1234, '', '192.168.254.254', ?, ?,
                        '', '', ?, 1, 'applied', ?, ?, 'onboard', ?, ?, ?, ?)
                    """,
                    (
                        board_id, name, ip, ip, ip, f"sim-{board_id}", udp_interface,
                        profile.get("source_ip", "192.168.1.10"),
                        target_profile,
                        timestamp, timestamp, timestamp,
                    ),
                )

    @staticmethod
    def _repair_auto_profiles(connection: sqlite3.Connection) -> None:
        for interface in ("enp225s0f0", "enp225s0f1"):
            profile = auto_fpga_link_profile(interface)
            if not profile:
                continue
            connection.execute(
                """UPDATE boards
                   SET udp_source_ip=CASE WHEN udp_source_ip='' THEN ? ELSE udp_source_ip END,
                       bootstrap_ip=CASE WHEN bootstrap_ip='' THEN ? ELSE bootstrap_ip END,
                       target_profile=CASE WHEN target_profile='' THEN ? ELSE target_profile END
                   WHERE udp_interface=?""",
                (
                    profile["source_ip"], profile["bootstrap_ip"], profile["target_profile"], interface,
                ),
            )

    @staticmethod
    def _cleanup_legacy_inventory(connection: sqlite3.Connection) -> None:
        timestamp = now()
        connection.execute(
            """UPDATE boards
               SET enabled=0,
                   notes=CASE
                     WHEN notes LIKE '%disabled by discovery-only migration%' THEN notes
                     WHEN notes='' THEN 'disabled by discovery-only migration; rescan RFCTRL2 to add real inventory'
                     ELSE notes || '\n' || 'disabled by discovery-only migration; rescan RFCTRL2 to add real inventory'
                   END,
                   updated_at=?
               WHERE enabled=1
                 AND (
                   device_uid=''
                   OR last_seen_at=''
                   OR active_mac=''
                 )""",
            (timestamp,),
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
            id=row["id"], name=row["name"], model=row["model"], ip=row["ip"], port=int(row["port"]),
            mac=row["mac"], udp_interface=row["udp_interface"], udp_source_ip=row["udp_source_ip"],
            bootstrap_ip=row["bootstrap_ip"], desired_ip=row["desired_ip"] or row["ip"],
            active_ip=row["active_ip"] or row["ip"], desired_mac=row["desired_mac"] or row["mac"],
            active_mac=row["active_mac"] or row["mac"], device_uid=row["device_uid"],
            network_revision=int(row["network_revision"]), network_apply_status=row["network_apply_status"],
            network_apply_error=row["network_apply_error"],
            clock_source=row["clock_source"], target_profile=row["target_profile"],
            jtag_cable_serial=row["jtag_cable_serial"], serial_path=row["serial_path"], baud_rate=int(row["baud_rate"]),
            serial_status=row["serial_status"], serial_error=row["serial_error"], location=row["location"], notes=row["notes"],
            last_seen_at=row["last_seen_at"], enabled=bool(row["enabled"]), lease=self._lease(row),
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
            rows = connection.execute(
                self._board_query() + " WHERE boards.enabled = 1 ORDER BY boards.name COLLATE NOCASE"
            ).fetchall()
        return [self._board(row) for row in rows]

    def list_inventory_records(self) -> list[BoardProfile]:
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
        raise ManagementError("board inventory is discovery-only; run RFCTRL2 network scan to add boards")

    def update_board(self, board_id: str, request: BoardUpdateRequest) -> BoardProfile:
        self._write_board(board_id, request, create=False)
        return self.board(board_id)

    def update_network_state(
        self,
        board_id: str,
        *,
        desired_ip: str | None = None,
        desired_mac: str | None = None,
        active_ip: str | None = None,
        active_mac: str | None = None,
        device_uid: str | None = None,
        revision: int | None = None,
        status: str | None = None,
        error: str | None = None,
    ) -> BoardProfile:
        fields: list[str] = []
        values: list[object] = []
        updates = {
            "desired_ip": desired_ip,
            "desired_mac": desired_mac,
            "active_ip": active_ip,
            "active_mac": active_mac,
            "device_uid": device_uid,
            "network_revision": revision,
            "network_apply_status": status,
            "network_apply_error": error,
        }
        for field, value in updates.items():
            if value is not None:
                fields.append(f"{field}=?")
                values.append(value)
        if not fields:
            return self.board(board_id)
        if active_ip is not None:
            fields.append("ip=?")
            values.append(active_ip)
        if active_mac is not None:
            fields.append("mac=?")
            values.append(active_mac)
        fields.append("updated_at=?")
        values.append(now())
        values.append(board_id)
        with self._transaction(immediate=True) as connection:
            if connection.execute("SELECT 1 FROM boards WHERE id=?", (board_id,)).fetchone() is None:
                raise KeyError(f"unknown board {board_id}")
            connection.execute(f"UPDATE boards SET {', '.join(fields)} WHERE id=?", values)
        return self.board(board_id)

    def allocated_ip_for_discovery(self, interface: str, device_uid: str, active_mac: str = "") -> str:
        pool = ip_pool_for_interface(interface)
        profile = auto_fpga_link_profile(interface) or {}
        with self._transaction() as connection:
            mac_clause = ""
            params: list[str] = [device_uid]
            if active_mac:
                mac_clause = " AND (active_mac=? OR mac=?)"
                params.extend([active_mac, active_mac])
            existing = connection.execute(
                "SELECT desired_ip, active_ip, ip, udp_interface FROM boards WHERE device_uid=?"
                + mac_clause
                + " ORDER BY last_seen_at DESC, updated_at DESC",
                params,
            ).fetchone()
            if existing:
                for field in ("desired_ip", "active_ip", "ip"):
                    value = existing[field]
                    if pool and value in pool:
                        return str(value)
                if not pool and existing["ip"]:
                    return str(existing["ip"])
            rows = connection.execute(
                "SELECT desired_ip, active_ip, ip FROM boards WHERE udp_interface=? AND enabled=1",
                (interface,),
            ).fetchall()
        if not pool:
            return profile.get("target_ip", "192.168.1.128")
        used = {
            str(value)
            for row in rows
            for value in (row["desired_ip"], row["active_ip"], row["ip"])
            if value
        }
        preferred = profile.get("target_ip", "")
        candidates = [preferred] + [address for address in pool if address != preferred]
        for address in candidates:
            if not address:
                continue
            if address not in used:
                return address
        raise ManagementError(f"no free FPGA IP addresses remain for {interface}")

    def upsert_discovered_board(
        self,
        *,
        device_uid: str,
        udp_interface: str,
        active_ip: str,
        active_mac: str,
        desired_ip: str,
        desired_mac: str,
        network_revision: int,
        network_apply_status: str,
        network_apply_error: str = "",
        target_profile: str = "",
    ) -> BoardProfile:
        def mac_match(left: str, right: str) -> bool:
            return (left or "").replace(":", "").lower() == (right or "").replace(":", "").lower()

        if not device_uid:
            raise ManagementError("discovered FPGA did not report device_uid")
        profile = auto_fpga_link_profile(udp_interface) or {}
        resolved_target_profile = target_profile or profile.get("target_profile", "custom_xczu47dr")
        resolved_target_profile = (
            resolved_target_profile
            if resolved_target_profile in {
                "custom_xczu47dr",
                "custom_xczu47dr_master",
                "custom_xczu47dr_slave",
                "custom_xczu47dr_bw",
            }
            else "custom_xczu47dr"
        )
        resolved_clock_source = "onboard"
        inventory_name = profile.get("inventory_name", "")
        jtag_cable_serial = profile.get("jtag_cable_serial", "")
        serial_path = profile.get("serial_path", "")
        timestamp = now()
        suffix = "".join(ch.lower() for ch in device_uid if ch.isalnum())[-8:] or uuid.uuid4().hex[:8]
        preferred_id = f"fpga-{suffix}"
        with self._transaction(immediate=True) as connection:
            rows = connection.execute(
                "SELECT id, name, active_mac, mac FROM boards WHERE device_uid=? ORDER BY enabled DESC, last_seen_at DESC, updated_at DESC",
                (device_uid,),
            ).fetchall()
            if active_mac:
                matches = [item for item in rows if mac_match(item["active_mac"] or item["mac"], active_mac)]
                row = matches[0] if matches else None
                duplicates = [
                    item for item in rows
                    if (row is None or item["id"] != row["id"]) and mac_match(item["active_mac"] or item["mac"], active_mac)
                ]
            else:
                row = rows[0] if rows else None
                duplicates = rows[1:] if row else []
            for duplicate in duplicates:
                connection.execute(
                    """UPDATE boards
                       SET enabled=0,
                           notes=CASE
                             WHEN notes LIKE '%disabled duplicate device_uid%' THEN notes
                             WHEN notes='' THEN 'disabled duplicate device_uid; inventory is keyed by RFCTRL2 device_uid'
                             ELSE notes || '\n' || 'disabled duplicate device_uid; inventory is keyed by RFCTRL2 device_uid'
                           END,
                           updated_at=?
                       WHERE id=?""",
                    (timestamp, duplicate["id"]),
                )
            board_id = row["id"] if row else preferred_id
            if row is None:
                while connection.execute("SELECT 1 FROM boards WHERE id=?", (board_id,)).fetchone() is not None:
                    board_id = f"fpga-{suffix}-{uuid.uuid4().hex[:4]}"
                name = inventory_name or f"FPGA {suffix.upper()}"
                connection.execute(
                    """
                    INSERT INTO boards(id, name, model, ip, port, mac, bootstrap_ip, desired_ip, active_ip,
                        desired_mac, active_mac, device_uid, network_revision, network_apply_status, network_apply_error,
                        udp_interface, udp_source_ip, clock_source, target_profile, jtag_cable_serial,
                        serial_path, baud_rate, location, notes, last_seen_at, enabled, created_at, updated_at)
                    VALUES (?, ?, 'XCZU47DR RFDC', ?, 1234, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                        ?, ?, 115200, '', '', ?, 1, ?, ?)
                    """,
                    (
                        board_id, name, active_ip, active_mac, profile.get("bootstrap_ip", "192.168.254.254"),
                        desired_ip, active_ip, desired_mac, active_mac, device_uid, network_revision,
                        network_apply_status, network_apply_error, udp_interface,
                        profile.get("source_ip", "192.168.1.10"), resolved_clock_source, resolved_target_profile,
                        jtag_cable_serial, serial_path, timestamp, timestamp, timestamp,
                    ),
                )
            else:
                connection.execute(
                    """
                    UPDATE boards SET name=CASE WHEN ?!='' THEN ? ELSE name END,
                        ip=?, mac=?, desired_ip=?, active_ip=?, desired_mac=?, active_mac=?,
                        device_uid=?,
                        udp_interface=?, udp_source_ip=?, bootstrap_ip=?, target_profile=?, clock_source=?,
                        jtag_cable_serial=CASE WHEN ?!='' THEN ? ELSE jtag_cable_serial END,
                        serial_path=CASE WHEN ?!='' THEN ? ELSE serial_path END,
                        network_revision=?, network_apply_status=?, network_apply_error=?,
                        last_seen_at=?, enabled=1, updated_at=?
                    WHERE id=?
                    """,
                    (
                        inventory_name, inventory_name,
                        active_ip, active_mac, desired_ip, active_ip, desired_mac, active_mac, device_uid,
                        udp_interface, profile.get("source_ip", "192.168.1.10"),
                        profile.get("bootstrap_ip", "192.168.254.254"),
                        resolved_target_profile, resolved_clock_source,
                        jtag_cable_serial, jtag_cable_serial, serial_path, serial_path,
                        network_revision, network_apply_status, network_apply_error,
                        timestamp, timestamp, board_id,
                    ),
                )
        return self.board(board_id)

    def _write_board(self, board_id: str, request: BoardUpdateRequest, create: bool) -> None:
        values = request.model_dump()
        profile = auto_fpga_link_profile(values["udp_interface"])
        if create and profile:
            values.update({
                "ip": profile["target_ip"],
                "desired_ip": profile["target_ip"],
                "active_ip": profile["target_ip"],
                "mac": profile["target_mac"],
                "desired_mac": profile["target_mac"],
                "active_mac": profile["target_mac"],
                "bootstrap_ip": profile["bootstrap_ip"],
                "udp_source_ip": profile["source_ip"],
                "target_profile": profile["target_profile"],
                "clock_source": "onboard",
            })
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
                    INSERT INTO boards(id, name, model, ip, port, mac, bootstrap_ip, desired_ip, active_ip,
                        desired_mac, active_mac, device_uid, network_revision, network_apply_status, network_apply_error,
                        udp_interface, udp_source_ip, clock_source, target_profile, jtag_cable_serial,
                        serial_path, baud_rate, location, notes, enabled, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (board_id, values["name"], values["model"], values["ip"], values["port"], values["mac"],
                     values["bootstrap_ip"], values["desired_ip"], values["active_ip"], values["desired_mac"], values["active_mac"],
                     values["device_uid"], values["network_revision"], values["network_apply_status"], values["network_apply_error"],
                     values["udp_interface"], values["udp_source_ip"], values["clock_source"], values["target_profile"],
                     values["jtag_cable_serial"], values["serial_path"], values["baud_rate"], values["location"], values["notes"],
                     int(values["enabled"]), timestamp, timestamp),
                )
            else:
                connection.execute(
                    """
                    UPDATE boards SET name=?, model=?, ip=?, port=?, mac=?, bootstrap_ip=?, desired_ip=?, active_ip=?,
                        desired_mac=?, active_mac=?, device_uid=?, network_revision=?, network_apply_status=?, network_apply_error=?,
                        udp_interface=?, udp_source_ip=?, clock_source=?, target_profile=?, jtag_cable_serial=?,
                        serial_path=?, baud_rate=?, location=?, notes=?, enabled=?, updated_at=?
                    WHERE id=?
                    """,
                    (values["name"], values["model"], values["ip"], values["port"], values["mac"],
                     values["bootstrap_ip"], values["desired_ip"], values["active_ip"], values["desired_mac"], values["active_mac"],
                     values["device_uid"], values["network_revision"], values["network_apply_status"], values["network_apply_error"],
                     values["udp_interface"], values["udp_source_ip"], values["clock_source"], values["target_profile"],
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

    def list_phase_calibrations(self, board_id: str) -> list[PhaseCalibrationRecord]:
        board = self.board(board_id)
        if not board.device_uid:
            return []
        with self._transaction() as connection:
            rows = connection.execute(
                """SELECT c.*, u.username AS updated_by_name
                   FROM phase_calibrations AS c
                   LEFT JOIN users AS u ON u.id=c.updated_by
                   WHERE c.device_uid=?
                   ORDER BY c.frequency_hz, c.channel""",
                (board.device_uid,),
            ).fetchall()
        return [
            PhaseCalibrationRecord(
                board_id=board_id,
                device_uid=row["device_uid"],
                frequency_hz=int(row["frequency_hz"]),
                channel=int(row["channel"]),
                phase_deg=float(row["phase_deg"]),
                updated_at=row["updated_at"],
                updated_by=row["updated_by_name"],
            )
            for row in rows
        ]

    def save_phase_calibration(
        self, board_id: str, request: PhaseCalibrationRequest, user: UserRecord
    ) -> PhaseCalibrationRecord:
        board = self.board(board_id)
        if not board.device_uid:
            raise ManagementError("板卡尚未完成 RFCTRL2 discovery，不能保存相位校准")
        timestamp = now()
        with self._transaction(immediate=True) as connection:
            connection.execute(
                """INSERT INTO phase_calibrations(device_uid, frequency_hz, channel, phase_deg, updated_by, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?)
                   ON CONFLICT(device_uid, frequency_hz, channel) DO UPDATE SET
                     phase_deg=excluded.phase_deg, updated_by=excluded.updated_by, updated_at=excluded.updated_at""",
                (board.device_uid, request.frequency_hz, request.channel, request.phase_deg, user.id, timestamp),
            )
        return next(
            item for item in self.list_phase_calibrations(board_id)
            if item.frequency_hz == request.frequency_hz and item.channel == request.channel
        )

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
