import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

from pydantic import ValidationError

from software.webapp.controller import EventHub
from software.webapp.hardware_services import DiscoveryService, ProgrammerService, SerialService
from software.webapp.management import ManagementError, ManagementStore, PermissionError
from software.webapp.models import (
    BoardUpdateRequest,
    PerformanceTestCreateRequest,
    RunCreateRequest,
    UserCreateRequest,
    UserRole,
)


class ManagementStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.store = ManagementStore(Path(self.temp_dir.name) / "rfsoc_web.sqlite3")
        self.admin = self.store.authenticate("admin", "admin12345")
        assert self.admin is not None

    def tearDown(self):
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

    def test_board_profile_accepts_only_the_two_server_udp_ports(self):
        board = self.store.board("board-a")
        values = board.model_dump(exclude={"id", "lease", "serial_status", "serial_error"})
        values["udp_interface"] = "enp225s0f1"
        request = BoardUpdateRequest(**values)
        self.assertEqual(request.udp_interface, "enp225s0f1")
        values["udp_interface"] = "eno1np0"
        with self.assertRaises(ValidationError):
            BoardUpdateRequest(**values)

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
