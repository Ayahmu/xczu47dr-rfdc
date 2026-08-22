import tempfile
import unittest
import os
import sqlite3
from pathlib import Path
from unittest.mock import Mock

from software.webapp.controller import EventHub
from software.webapp.hardware_services import DiscoveryService, ProgrammerService, SerialService
from software.webapp.management import ManagementError, ManagementStore, PermissionError
from software.webapp.models import (
    BoardUpdateRequest,
    PhaseCalibrationRequest,
    PerformanceTestCreateRequest,
    RunCreateRequest,
    UserCreateRequest,
    UserRole,
)


class ManagementStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.old_simulation = os.environ.get("RFSOC_WEB_SIMULATION")
        self.old_seed_boards = os.environ.get("RFSOC_WEB_SEED_SIMULATION_BOARDS")
        os.environ["RFSOC_WEB_SIMULATION"] = "1"
        os.environ["RFSOC_WEB_SEED_SIMULATION_BOARDS"] = "1"
        self.store = ManagementStore(Path(self.temp_dir.name) / "rfsoc_web.sqlite3")
        self.admin = self.store.authenticate("admin", "admin12345")
        assert self.admin is not None

    def tearDown(self):
        if self.old_simulation is None:
            os.environ.pop("RFSOC_WEB_SIMULATION", None)
        else:
            os.environ["RFSOC_WEB_SIMULATION"] = self.old_simulation
        if self.old_seed_boards is None:
            os.environ.pop("RFSOC_WEB_SEED_SIMULATION_BOARDS", None)
        else:
            os.environ["RFSOC_WEB_SEED_SIMULATION_BOARDS"] = self.old_seed_boards
        self.temp_dir.cleanup()

    def test_default_inventory_and_exclusive_lease(self):
        boards = self.store.list_boards()
        self.assertEqual([board.id for board in boards], ["board-a", "board-b"])
        alice = self.store.create_user(UserCreateRequest(username="alice", password="password123", role=UserRole.USER))
        bob = self.store.create_user(UserCreateRequest(username="bob", password="password123", role=UserRole.USER))
        self.assertEqual(self.store.lease_board("board-a", alice).lease.user_id, alice.id)
        with self.assertRaises(ManagementError):
            self.store.lease_board("board-a", bob)
        with self.assertRaises(PermissionError):
            self.store.release_board("board-a", bob)
        self.assertIsNone(self.store.release_board("board-a", self.admin, force=True).lease)

    def test_live_execution_is_the_api_default(self):
        self.assertFalse(RunCreateRequest.model_fields["dry_run"].default)
        self.assertFalse(PerformanceTestCreateRequest.model_fields["dry_run"].default)

    def test_live_inventory_starts_empty_until_network_scan(self):
        os.environ.pop("RFSOC_WEB_SIMULATION", None)
        os.environ.pop("RFSOC_WEB_SEED_SIMULATION_BOARDS", None)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = ManagementStore(Path(temp_dir) / "rfsoc_web.sqlite3")
            self.assertEqual(store.list_boards(), [])

    def test_board_inventory_schema_has_no_sync_role_columns(self):
        with self.store._transaction() as connection:
            columns = {row["name"] for row in connection.execute("PRAGMA table_info(boards)").fetchall()}
        self.assertNotIn("role", columns)
        self.assertNotIn("sync_group", columns)

    def test_legacy_board_role_columns_are_migrated_away(self):
        os.environ.pop("RFSOC_WEB_SIMULATION", None)
        os.environ.pop("RFSOC_WEB_SEED_SIMULATION_BOARDS", None)
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "rfsoc_web.sqlite3"
            timestamp = "2026-01-01T00:00:00+00:00"
            connection = sqlite3.connect(path)
            try:
                connection.execute(
                    """
                    CREATE TABLE boards (
                        id TEXT PRIMARY KEY,
                        name TEXT NOT NULL,
                        model TEXT NOT NULL DEFAULT '',
                        role TEXT NOT NULL CHECK(role IN ('master')),
                        ip TEXT NOT NULL,
                        port INTEGER NOT NULL,
                        mac TEXT NOT NULL DEFAULT '',
                        udp_interface TEXT NOT NULL,
                        udp_source_ip TEXT NOT NULL,
                        clock_source TEXT NOT NULL CHECK(clock_source IN ('onboard')),
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
                    )
                    """
                )
                connection.execute(
                    """INSERT INTO boards(
                        id, name, model, role, ip, port, mac, udp_interface, udp_source_ip,
                        clock_source, target_profile, sync_group, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        "legacy-board", "Legacy", "XCZU47DR RFDC", "master",
                        "192.168.1.128", 1234, "", "enp225s0f0", "192.168.1.10",
                        "onboard", "custom_xczu47dr", "pair-a", timestamp, timestamp,
                    ),
                )
                connection.commit()
            finally:
                connection.close()

            store = ManagementStore(path)
            with store._transaction() as migrated:
                columns = {row["name"] for row in migrated.execute("PRAGMA table_info(boards)").fetchall()}
            self.assertNotIn("role", columns)
            self.assertNotIn("sync_group", columns)
            self.assertEqual(store.list_inventory_records()[0].id, "legacy-board")

    def test_startup_disables_any_legacy_board_without_discovery_identity(self):
        os.environ.pop("RFSOC_WEB_SIMULATION", None)
        os.environ.pop("RFSOC_WEB_SEED_SIMULATION_BOARDS", None)
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "rfsoc_web.sqlite3"
            store = ManagementStore(path)
            timestamp = "2026-01-01T00:00:00+00:00"
            with store._transaction(immediate=True) as connection:
                connection.execute(
                    """
                    INSERT INTO boards(
                        id, name, model, ip, port, mac, udp_interface, udp_source_ip,
                        clock_source, target_profile, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        "old-manual-board", "Old manual board", "XCZU47DR RFDC",
                        "192.168.1.128", 1234, "", "enp225s0f0", "192.168.1.10",
                        "onboard", "custom_xczu47dr", timestamp, timestamp,
                    ),
                )
            reopened = ManagementStore(path)
            self.assertEqual(reopened.list_boards(), [])
            record = reopened.list_inventory_records()[0]
            self.assertFalse(record.enabled)
            self.assertEqual(record.device_uid, "")

    def test_discovered_board_upsert_reuses_uid_and_allocated_ip(self):
        self.assertEqual(
            self.store.allocated_ip_for_discovery("enp225s0f1", "0000000047d00081"),
            "192.168.2.129",
        )
        board = self.store.upsert_discovered_board(
            device_uid="0000000047d00081",
            udp_interface="enp225s0f1",
            active_ip="192.168.2.129",
            active_mac="02:47:d0:00:00:81",
            desired_ip="192.168.2.129",
            desired_mac="02:47:d0:00:00:81",
            network_revision=1,
            network_apply_status="applied",
        )
        self.assertEqual(board.id, "fpga-47d00081")
        self.assertEqual(board.udp_interface, "enp225s0f1")
        self.assertEqual(board.ip, "192.168.2.129")
        second_ip = self.store.allocated_ip_for_discovery("enp225s0f1", "0000000047d00082")
        self.assertEqual(second_ip, "192.168.2.130")
        updated = self.store.upsert_discovered_board(
            device_uid="0000000047d00081",
            udp_interface="enp225s0f1",
            active_ip="192.168.2.129",
            active_mac="02:47:d0:00:00:81",
            desired_ip="192.168.2.129",
            desired_mac="02:47:d0:00:00:81",
            network_revision=2,
            network_apply_status="applied",
        )
        self.assertEqual(updated.id, board.id)
        self.assertEqual(len([item for item in self.store.list_boards() if item.device_uid == "0000000047d00081"]), 1)

    def test_same_device_uid_boards_are_keyed_by_active_mac(self):
        device_uid = "0000000047d00000"
        first = self.store.upsert_discovered_board(
            device_uid=device_uid,
            udp_interface="enp225s0f0",
            active_ip="169.254.32.1",
            active_mac="02:00:00:2c:d6:91",
            desired_ip="192.168.1.128",
            desired_mac="02:00:00:2c:d6:91",
            network_revision=1,
            network_apply_status="applied",
        )
        second = self.store.upsert_discovered_board(
            device_uid=device_uid,
            udp_interface="enp225s0f1",
            active_ip="169.254.32.1",
            active_mac="02:00:00:ad:15:91",
            desired_ip="192.168.2.128",
            desired_mac="02:00:00:ad:15:91",
            network_revision=1,
            network_apply_status="applied",
        )

        self.assertNotEqual(first.id, second.id)
        self.assertEqual(first.udp_interface, "enp225s0f0")
        self.assertEqual(second.udp_interface, "enp225s0f1")
        self.assertEqual(first.name, "XCZU47DR 081")
        self.assertEqual(second.name, "XCZU47DR 082")
        self.assertEqual(first.target_profile, "custom_xczu47dr_master")
        self.assertEqual(second.target_profile, "custom_xczu47dr_slave")
        self.assertEqual(first.jtag_cable_serial, "210512180081")
        self.assertEqual(second.jtag_cable_serial, "210512180082")
        self.assertEqual(
            [item.id for item in self.store.list_boards() if item.device_uid == device_uid],
            [first.id, second.id],
        )
        self.assertEqual(
            self.store.allocated_ip_for_discovery("enp225s0f0", device_uid, active_mac="02:00:00:2c:d6:91"),
            "192.168.1.128",
        )
        self.assertEqual(
            self.store.allocated_ip_for_discovery("enp225s0f1", device_uid, active_mac="02:00:00:ad:15:91"),
            "192.168.2.128",
        )

    def test_startup_keeps_same_uid_discovered_boards_and_disables_only_placeholder(self):
        device_uid = "51ec34c000002001"
        timestamp = "2026-01-01T00:00:00+00:00"
        with self.store._transaction(immediate=True) as connection:
            for board_id, name, interface, source_ip, ip, mac in (
                ("discovered-081", "XCZU47DR 081", "enp225s0f0", "192.168.1.10", "192.168.1.128", "02:00:00:2c:d6:91"),
                ("discovered-082", "XCZU47DR 082", "enp225s0f1", "192.168.2.10", "192.168.2.128", "02:00:00:ad:15:91"),
            ):
                connection.execute(
                    """INSERT INTO boards(
                        id, name, model, ip, port, mac, bootstrap_ip, desired_ip, active_ip,
                        desired_mac, active_mac, device_uid, network_revision, network_apply_status,
                        udp_interface, udp_source_ip, clock_source, target_profile, last_seen_at,
                        enabled, created_at, updated_at
                    ) VALUES (?, ?, 'XCZU47DR RFDC', ?, 1234, ?, '192.168.254.254', ?, ?, ?, ?, ?, 1, 'applied', ?, ?, 'onboard', ?, ?, 1, ?, ?)""",
                    (
                        board_id, name, ip, mac, ip, ip, mac, mac, device_uid, interface, source_ip,
                        "custom_xczu47dr_master" if interface.endswith("f0") else "custom_xczu47dr_slave",
                        timestamp, timestamp, timestamp,
                    ),
                )
            connection.execute(
                """INSERT INTO boards(
                    id, name, model, ip, port, mac, bootstrap_ip, desired_ip, active_ip,
                    desired_mac, active_mac, device_uid, udp_interface, udp_source_ip,
                    clock_source, target_profile, enabled, created_at, updated_at
                ) VALUES (?, ?, 'XCZU47DR RFDC', ?, 1234, '', '192.168.254.254', '', '', '', '', '', ?, ?, 'onboard', 'custom_xczu47dr', 1, ?, ?)""",
                ("legacy-placeholder", "Legacy placeholder", "192.168.1.128", "enp225s0f0", "192.168.1.10", timestamp, timestamp),
            )
        reopened = ManagementStore(self.store.path)
        records = {record.id: record for record in reopened.list_inventory_records()}
        self.assertTrue(records["discovered-081"].enabled)
        self.assertTrue(records["discovered-082"].enabled)
        self.assertFalse(records["legacy-placeholder"].enabled)

    def test_phase_calibration_is_keyed_by_exact_frequency_and_channel(self):
        saved = self.store.save_phase_calibration(
            "board-a",
            PhaseCalibrationRequest(frequency_hz=4_500_000_000, channel=2, phase_deg=12.5),
            self.admin,
        )
        self.assertEqual(saved.device_uid, "sim-board-a")
        self.assertEqual(saved.frequency_hz, 4_500_000_000)
        self.assertEqual(saved.phase_deg, 12.5)
        self.store.save_phase_calibration(
            "board-a",
            PhaseCalibrationRequest(frequency_hz=4_500_001_000, channel=2, phase_deg=-3.0),
            self.admin,
        )
        records = self.store.list_phase_calibrations("board-a")
        self.assertEqual(
            [(item.frequency_hz, item.channel, item.phase_deg) for item in records],
            [(4_500_000_000, 2, 12.5), (4_500_001_000, 2, -3.0)],
        )

    def test_empty_interface_pool_uses_profile_target_before_other_addresses(self):
        os.environ.pop("RFSOC_WEB_SIMULATION", None)
        os.environ.pop("RFSOC_WEB_SEED_SIMULATION_BOARDS", None)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = ManagementStore(Path(temp_dir) / "rfsoc_web.sqlite3")
            self.assertEqual(
                store.allocated_ip_for_discovery("enp225s0f1", "0000000047d00099"),
                "192.168.2.128",
            )

    def test_discovery_reenables_previously_disabled_uid_record(self):
        board = self.store.upsert_discovered_board(
            device_uid="0000000047d00091",
            udp_interface="enp225s0f0",
            active_ip="192.168.1.128",
            active_mac="02:47:d0:00:00:91",
            desired_ip="192.168.1.128",
            desired_mac="02:47:d0:00:00:91",
            network_revision=1,
            network_apply_status="applied",
        )
        values = board.model_dump(exclude={"id", "lease", "serial_status", "serial_error"})
        values["enabled"] = False
        request = BoardUpdateRequest(**values)
        self.store.update_board(board.id, request)
        self.assertNotIn(board.id, [item.id for item in self.store.list_boards()])

        updated = self.store.upsert_discovered_board(
            device_uid="0000000047d00091",
            udp_interface="enp225s0f0",
            active_ip="192.168.1.128",
            active_mac="02:47:d0:00:00:91",
            desired_ip="192.168.1.128",
            desired_mac="02:47:d0:00:00:91",
            network_revision=2,
            network_apply_status="applied",
        )

        self.assertTrue(updated.enabled)
        self.assertIn(board.id, [item.id for item in self.store.list_boards()])

    def test_default_boards_use_independent_10g_paths(self):
        board_a = self.store.board("board-a")
        board_b = self.store.board("board-b")
        self.assertEqual(
            (board_a.ip, board_a.udp_interface, board_a.udp_source_ip),
            ("192.168.1.128", "enp225s0f0", "192.168.1.10"),
        )
        self.assertEqual(
            (board_b.ip, board_b.udp_interface, board_b.udp_source_ip),
            ("192.168.2.128", "enp225s0f1", "192.168.2.10"),
        )

    def test_board_profile_accepts_detected_network_interfaces(self):
        board = self.store.board("board-a")
        values = board.model_dump(exclude={"id", "lease", "serial_status", "serial_error"})
        values["udp_interface"] = "enp225s0f1"
        request = BoardUpdateRequest(**values)
        self.assertEqual(request.udp_interface, "enp225s0f1")
        values["udp_interface"] = "eno2np1"
        request = BoardUpdateRequest(**values)
        self.assertEqual(request.udp_interface, "eno2np1")
        values["udp_interface"] = "eno3"
        request = BoardUpdateRequest(**values)
        self.assertEqual(request.udp_interface, "eno3")

    def test_discovery_moves_to_registered_after_exact_binding(self):
        pending = self.store.upsert_discovery(
            "jtag", "jtag:210512180081:xczu47dr", "210512180081",
            {"cable_serial": "210512180081", "part": "xczu47dr-ffvg1517-2-i"},
        )
        self.assertEqual(pending.state, "pending")
        board = self.store.board("board-a")
        request = BoardUpdateRequest(
            **board.model_dump(exclude={"id", "lease", "serial_status", "serial_error", "jtag_cable_serial"}),
            jtag_cable_serial="210512180081",
        )
        self.store.update_board("board-a", request)
        discovered = self.store.discoveries()[0]
        self.assertEqual(discovered.state, "registered")
        self.assertEqual(discovered.board_id, "board-a")

    def test_session_and_artifact_metadata(self):
        token, csrf = self.store.create_session(self.admin)
        user, stored_csrf = self.store.session_user(token)
        self.assertEqual(user.id, self.admin.id)
        self.assertEqual(stored_csrf, csrf)
        root = Path(self.temp_dir.name) / "artifact"
        root.mkdir()
        bit = root / "test.bit"
        elf = root / "test.elf"
        bit.write_bytes(b"bit")
        elf.write_bytes(b"elf")
        artifact = self.store.add_artifact(
            label="smoke", target_profile="custom_xczu47dr", bit_name=bit.name, elf_name=elf.name,
            bit_path=bit, elf_path=elf, bit_sha256="a" * 64, elf_sha256="b" * 64,
            bit_size=3, elf_size=3, user=self.admin,
        )
        self.assertEqual(self.store.artifact_paths(artifact.id), (bit, elf))
        self.assertEqual(self.store.list_artifacts()[0].id, artifact.id)

        first_job = self.store.create_program_job("board-a", artifact.id, self.admin)
        with self.assertRaisesRegex(ManagementError, first_job.id):
            self.store.create_program_job("board-a", artifact.id, self.admin)

    def test_programming_preflight_requires_exact_cable(self):
        board = self.store.board("board-a")
        request = BoardUpdateRequest(
            **board.model_dump(exclude={"id", "lease", "serial_status", "serial_error", "jtag_cable_serial"}),
            jtag_cable_serial="210512180081",
        )
        board = self.store.update_board("board-a", request)
        discovery = Mock()
        programmer = ProgrammerService(self.store, Mock(), Mock(), Mock(), discovery, Mock())

        discovery.scan_jtag.return_value = ([{
            "cable_serial": "210512180081", "part": "", "availability": "present",
        }], "")
        programmer._verify_jtag(board)

        discovery.scan_jtag.return_value = ([{
            "cable_serial": "210512180082", "part": "xczu47dr-ffvg1517-2-i",
        }], "")
        with self.assertRaisesRegex(ManagementError, "was not found"):
            programmer._verify_jtag(board)

    def test_jtag_scan_uses_linux_usb_sysfs(self):
        serial = Mock()
        boards = Mock()
        discovery = DiscoveryService(self.store, boards, serial, EventHub())
        usb_root = Path(self.temp_dir.name) / "usb"
        for name, vendor, product, manufacturer, serial_number in (
            ("1-1", "0403", "6014", "Digilent", "210251A08870"),
            ("3-1", "0403", "6014", "Digilent", "210512180081"),
            ("1-2", "0403", "6001", "FTDI", "AQ04KVC8"),
        ):
            device = usb_root / name
            device.mkdir(parents=True)
            (device / "idVendor").write_text(vendor, encoding="utf-8")
            (device / "idProduct").write_text(product, encoding="utf-8")
            (device / "manufacturer").write_text(manufacturer, encoding="utf-8")
            (device / "product").write_text("Digilent USB Device", encoding="utf-8")
            (device / "serial").write_text(serial_number, encoding="utf-8")
        discovery.usb_devices_root = usb_root

        resources, error = discovery.scan_jtag()
        self.assertEqual(error, "")
        self.assertEqual({item["cable_serial"] for item in resources}, {"210512180081", "210251A08870"})
        self.assertTrue(all(item["availability"] == "present" for item in resources))
        self.assertTrue(all(item["scan_scope"] == "linux-usb" for item in resources))
        self.assertTrue(all(item["part"] == "" and item["programmed"] == "unknown" for item in resources))

    def test_serial_discovery_only_returns_ttyusb_paths(self):
        serial_module = Mock()
        serial_module.tools.list_ports.comports.return_value = [
            Mock(device="/dev/ttyUSB0", manufacturer="FTDI", serial_number="UART0", vid=0x0403, pid=0x6001),
            Mock(device="/dev/ttyUSB12", manufacturer="FTDI", serial_number="UART12", vid=0x0403, pid=0x6001),
            Mock(device="/dev/ttyS0", manufacturer=None, serial_number=None, vid=None, pid=None),
            Mock(device="/dev/ttyACM0", manufacturer="Other", serial_number="ACM0", vid=0x1234, pid=0x5678),
        ]
        service = SerialService(self.store, EventHub())
        service._serial_module = lambda: serial_module  # type: ignore[method-assign]

        ports = service.discover()

        self.assertEqual([item.path for item in ports], ["/dev/ttyUSB0", "/dev/ttyUSB12"])
        self.assertTrue(all(item.stable_path == "" for item in ports))
        serial_resources = [item for item in self.store.discoveries() if item.kind == "serial"]
        self.assertEqual({item.label for item in serial_resources}, {"/dev/ttyUSB0", "/dev/ttyUSB12"})


if __name__ == "__main__":
    unittest.main()
