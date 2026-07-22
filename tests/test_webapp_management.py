import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from software.webapp.controller import EventHub
from software.webapp.hardware_services import DiscoveryService, ProgrammerService
from software.webapp.management import ManagementError, ManagementStore, PermissionError
from software.webapp.models import BoardUpdateRequest, UserCreateRequest, UserRole


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

    def test_programming_preflight_requires_exact_cable_and_part(self):
        board = self.store.board("board-a")
        request = BoardUpdateRequest(
            **board.model_dump(exclude={"id", "lease", "serial_status", "serial_error", "jtag_cable_serial"}),
            jtag_cable_serial="210512180081",
        )
        board = self.store.update_board("board-a", request)
        discovery = Mock()
        programmer = ProgrammerService(self.store, Mock(), Mock(), Mock(), discovery, Mock())

        discovery.scan_jtag.return_value = ([{
            "cable_serial": "210512180081", "part": "xczu47dr-ffvg1517-2-i",
        }], "another target is already opened")
        programmer._verify_jtag(board)

        discovery.scan_jtag.return_value = ([{
            "cable_serial": "210512180081", "part": "", "availability": "busy_or_unopened",
            "error": "Target is already opened",
        }], "Target is already opened")
        with self.assertRaisesRegex(ManagementError, "is unavailable.*already opened"):
            programmer._verify_jtag(board)

        discovery.scan_jtag.return_value = ([{
            "cable_serial": "210512180082", "part": "xczu47dr-ffvg1517-2-i",
        }], "")
        with self.assertRaisesRegex(ManagementError, "was not found"):
            programmer._verify_jtag(board)

        discovery.scan_jtag.return_value = ([{
            "cable_serial": "210512180081", "part": "xczu48dr-ffvg1517-2-i",
        }], "")
        with self.assertRaisesRegex(ManagementError, "device mismatch"):
            programmer._verify_jtag(board)

    def test_jtag_scan_keeps_busy_target_as_discovered_resource(self):
        serial = Mock()
        boards = Mock()
        discovery = DiscoveryService(self.store, boards, serial, EventHub())
        discovery.vivado_bin = "/bin/true"
        output = "\n".join([
            "RFWEB_TARGET|localhost:3121/xilinx_tcf/Digilent/210512180081|210512180081",
            "RFWEB_TARGET_ERROR|localhost:3121/xilinx_tcf/Digilent/210512180081|Target is already opened",
        ])
        completed = Mock(stdout=output, stderr="", returncode=0)
        with patch("software.webapp.hardware_services.subprocess.run", return_value=completed):
            resources, error = discovery.scan_jtag()
        self.assertIn("already opened", error)
        self.assertEqual(resources[0]["cable_serial"], "210512180081")
        self.assertEqual(resources[0]["availability"], "busy_or_unopened")
        self.assertEqual(DiscoveryService._cable_from_target("localhost:3121/xilinx_tcf/Digilent/210251A08870"), "210251A08870")


if __name__ == "__main__":
    unittest.main()
