import sys
import unittest
from argparse import Namespace
from unittest.mock import patch
from importlib import util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOFTWARE_DIR = ROOT / "software"
sys.path.insert(0, str(SOFTWARE_DIR))


def load_software_module(module_name: str, filename: str):
    spec = util.spec_from_file_location(module_name, SOFTWARE_DIR / filename)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {filename}")
    module = util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


sync_two_boards = load_software_module("sync_two_boards", "sync_two_boards.py")


class TwoBoardSyncCliTests(unittest.TestCase):
    def test_dry_run_prints_plan_without_network(self):
        code = sync_two_boards.main([
            "--master-ip", "192.168.1.128",
            "--slave-ip", "192.168.1.129",
            "--dry-run",
        ])
        self.assertEqual(code, 0)

    def test_dry_run_with_apply_arm_trigger(self):
        code = sync_two_boards.main([
            "--master-ip", "192.168.1.128",
            "--slave-ip", "192.168.1.129",
            "--apply-arm-trigger",
            "--dry-run",
        ])
        self.assertEqual(code, 0)

    def test_separate_master_and_slave_interfaces(self):
        clients = []

        class FakeClient:
            def __init__(self, ip, **kwargs):
                clients.append((ip, kwargs))

        args = Namespace(timeout_s=2.0)
        with patch.object(sync_two_boards.host, "RFSocController", FakeClient):
            sync_two_boards._open_client(
                "169.254.32.1", 1234, "enp225s0f1", "169.254.250.11", args
            )

        self.assertEqual(clients[0][1]["udp_interface"], "enp225s0f1")
        self.assertEqual(clients[0][1]["udp_source_ip"], "169.254.250.11")


if __name__ == "__main__":
    unittest.main()
