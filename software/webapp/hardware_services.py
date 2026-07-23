from __future__ import annotations

import os
import re
import shutil
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .controller import BoardGateway, EventHub, RunCoordinator
from .management import ManagementError, ManagementStore
from .models import BoardProfile, ProgramJob, SerialPortInfo, UserRecord


def emit(events: EventHub, event_type: str, data: object) -> None:
    payload = data.model_dump(mode="json") if hasattr(data, "model_dump") else data
    events.publish({"type": event_type, "data": payload})


class SerialService:
    """One read-only, reconnecting reader per configured board UART."""

    def __init__(self, store: ManagementStore, events: EventHub, log_limit: int = 5000) -> None:
        self.store = store
        self.events = events
        self.log_limit = log_limit
        self.reconnect_s = float(os.environ.get("RFSOC_WEB_SERIAL_RECONNECT_S", "3"))
        self._entries: dict[str, threading.Event] = {}
        self._lock = threading.Lock()

    @staticmethod
    def _serial_module():
        try:
            import serial  # type: ignore
            import serial.tools.list_ports  # type: ignore
        except ImportError as exc:
            raise ManagementError("pyserial is not installed; install software/requirements.txt") from exc
        return serial

    def discover(self) -> list[SerialPortInfo]:
        serial = self._serial_module()
        bound = {board.serial_path: board.id for board in self.store.list_boards() if board.serial_path}
        ports: list[SerialPortInfo] = []
        fingerprints: set[str] = set()
        for port in serial.tools.list_ports.comports():
            path = str(port.device)
            if re.fullmatch(r"ttyUSB\d+", Path(path).name) is None:
                continue
            info = SerialPortInfo(
                path=path,
                stable_path="",
                manufacturer=port.manufacturer or "",
                serial_number=port.serial_number or "",
                vendor_id=port.vid and f"{port.vid:04x}" or "",
                product_id=port.pid and f"{port.pid:04x}" or "",
                bound_board_id=bound.get(path),
            )
            fingerprint = f"serial:{path}"
            fingerprints.add(fingerprint)
            self.store.upsert_discovery(
                "serial", fingerprint, path,
                {"path": path, "stable_path": "", "serial_number": info.serial_number,
                 "manufacturer": info.manufacturer, "vendor_id": info.vendor_id, "product_id": info.product_id},
            )
            ports.append(info)
        self.store.prune_discoveries("serial", fingerprints)
        return sorted(ports, key=lambda item: item.path)

    def start(self) -> None:
        for board in self.store.list_boards():
            self.refresh_board(board.id)

    def stop(self) -> None:
        with self._lock:
            events = tuple(self._entries.values())
            self._entries.clear()
        for stop_event in events:
            stop_event.set()

    def refresh_board(self, board_id: str) -> None:
        self.stop_board(board_id)
        board = self.store.board(board_id)
        if not board.enabled or not board.serial_path:
            self.store.update_serial_state(board_id, "missing" if not board.serial_path else "disabled")
            return
        stop_event = threading.Event()
        with self._lock:
            self._entries[board_id] = stop_event
        thread = threading.Thread(target=self._read_loop, args=(board, stop_event), name=f"rfsoc-uart-{board_id}", daemon=True)
        thread.start()

    def stop_board(self, board_id: str) -> None:
        with self._lock:
            stop_event = self._entries.pop(board_id, None)
        if stop_event:
            stop_event.set()

    def wait_for_line(self, board_id: str, token: str, timeout_s: float, since: str = "") -> str | None:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            for item in self.store.serial_logs(board_id, limit=self.log_limit):
                if token in item.line and (not since or item.created_at >= since):
                    return item.line
            time.sleep(0.05)
        return None

    def _read_loop(self, board: BoardProfile, stop_event: threading.Event) -> None:
        while not stop_event.is_set():
            try:
                serial = self._serial_module()
                self.store.update_serial_state(board.id, "connecting")
                with serial.Serial(board.serial_path, board.baud_rate, timeout=0.5) as device:
                    self.store.update_serial_state(board.id, "open")
                    emit(self.events, "serial.status", {"board_id": board.id, "state": "open"})
                    while not stop_event.is_set():
                        raw = device.readline()
                        if not raw:
                            continue
                        line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
                        if not line:
                            continue
                        item = self.store.add_serial_log(board.id, line, self.log_limit)
                        emit(self.events, "serial.line", {"board_id": board.id, **item.model_dump(mode="json")})
            except Exception as exc:  # Hardware disconnects must keep retrying.
                self.store.update_serial_state(board.id, "error", str(exc))
                emit(self.events, "serial.status", {"board_id": board.id, "state": "error", "error": str(exc)})
                stop_event.wait(self.reconnect_s)


class DiscoveryService:
    DIGILENT_JTAG_IDS = {("0403", "6014")}

    def __init__(self, store: ManagementStore, boards: BoardGateway, serial: SerialService, events: EventHub) -> None:
        self.store = store
        self.boards = boards
        self.serial = serial
        self.events = events
        self.usb_devices_root = Path(os.environ.get("RFSOC_WEB_USB_SYSFS_ROOT", "/sys/bus/usb/devices"))

    def scan(self) -> dict[str, object]:
        serial_ports = self.serial.discover()
        jtag, scan_error = self.scan_jtag()
        statuses = self.boards.all_statuses(refresh=False)
        result = {
            "serial": [item.model_dump(mode="json") for item in serial_ports],
            "jtag": jtag,
            "network": [item.model_dump(mode="json") for item in statuses],
            "scan_error": scan_error,
        }
        emit(self.events, "inventory.scanned", result)
        return result

    def scan_jtag(self) -> tuple[list[dict[str, str]], str]:
        """Enumerate Digilent JTAG adapters directly from Linux USB sysfs."""
        if not self.usb_devices_root.is_dir():
            return [], f"USB sysfs path not found: {self.usb_devices_root}"

        def read_attribute(device: Path, name: str) -> str:
            try:
                return (device / name).read_text(encoding="utf-8").strip()
            except OSError:
                return ""

        resources: list[dict[str, str]] = []
        fingerprints: set[str] = set()
        try:
            devices = tuple(self.usb_devices_root.iterdir())
        except OSError as exc:
            return [], str(exc)

        for device in devices:
            vendor_id = read_attribute(device, "idVendor").lower()
            product_id = read_attribute(device, "idProduct").lower()
            if (vendor_id, product_id) not in self.DIGILENT_JTAG_IDS:
                continue
            manufacturer = read_attribute(device, "manufacturer")
            product = read_attribute(device, "product")
            if "digilent" not in f"{manufacturer} {product}".lower():
                continue
            cable = read_attribute(device, "serial")
            if not cable:
                continue
            details = {
                "target": "", "device": device.name, "part": "", "programmed": "unknown",
                "program_file": "", "cable_serial": cable, "availability": "present",
                "scan_scope": "linux-usb", "usb_path": str(device),
                "vendor_id": vendor_id, "product_id": product_id,
                "manufacturer": manufacturer, "product": product,
            }
            fingerprint = f"jtag:{cable}:usb"
            fingerprints.add(fingerprint)
            discovered = self.store.upsert_discovery("jtag", fingerprint, cable, details)
            resources.append({**details, "state": discovered.state, "board_id": discovered.board_id or ""})
        self.store.prune_discoveries("jtag", fingerprints)
        return sorted(resources, key=lambda item: item["cable_serial"]), ""


class ProgrammerService:
    def __init__(self, store: ManagementStore, boards: BoardGateway, runs: RunCoordinator,
                 events: EventHub, discovery: DiscoveryService, serial: SerialService) -> None:
        self.store = store
        self.boards = boards
        self.runs = runs
        self.events = events
        self.discovery = discovery
        self.serial = serial
        self._lock = threading.Lock()
        self._project_root = Path(__file__).resolve().parents[2]
        self._xsct = os.environ.get("RFSOC_WEB_XSCT_BIN", shutil.which("xsct") or "/tools/Xilinx/Vitis/2024.2/bin/xsct")
        self.timeout_s = int(os.environ.get("RFSOC_WEB_PROGRAM_TIMEOUT_S", "900"))
        self.verify_timeout_s = int(os.environ.get("RFSOC_WEB_PROGRAM_VERIFY_TIMEOUT_S", "20"))

    def create(self, board_id: str, artifact_id: str, user: UserRecord) -> ProgramJob:
        board = self.store.board(board_id)
        artifact = self.store.artifact(artifact_id)
        if not board.enabled:
            raise ManagementError("board is disabled")
        if board.target_profile != artifact.target_profile:
            raise ManagementError("artifact target profile does not match the board")
        if not board.jtag_cable_serial:
            raise ManagementError("board has no registered JTAG cable serial")
        if self.store.active_lease(board_id):
            raise ManagementError("release the board lease before programming")
        if self.runs.active_run_for_board(board_id):
            raise ManagementError("abort the active waveform run before programming")
        bit, elf = self.store.artifact_paths(artifact_id)
        if not bit.is_file() or not elf.is_file():
            raise ManagementError("artifact files are missing from server storage")
        if not Path(self._xsct).is_file():
            raise ManagementError(f"XSCT not found: {self._xsct}")
        if not self._psu_init(board.target_profile).is_file():
            raise ManagementError("PS initialization script is missing for this target profile")
        self._verify_jtag(board)
        job = self.store.create_program_job(board_id, artifact_id, user)
        thread = threading.Thread(target=self._run, args=(job.id,), name=f"rfsoc-program-{job.id}", daemon=True)
        thread.start()
        return job

    def _psu_init(self, target: str) -> Path:
        workspace = "custom_xczu47dr_bandwidth" if target == "custom_xczu47dr_bw" else "custom_xczu47dr"
        return self._project_root / "firmware" / "workspace" / workspace / "hw_platform" / "hw" / "psu_init.tcl"

    def _verify_jtag(self, board: BoardProfile) -> None:
        resources, error = self.discovery.scan_jtag()
        matches = [item for item in resources if item.get("cable_serial") == board.jtag_cable_serial]
        if not matches:
            if error:
                raise ManagementError(f"JTAG preflight failed: {error}")
            raise ManagementError(f"registered JTAG cable serial {board.jtag_cable_serial} was not found")
        # Linux USB inventory confirms the physical Digilent cable only.  The
        # board profile still gates the artifact, while controlled XSCT
        # deployment selects the exact serial and performs target operations.

    def _command(self, board: BoardProfile, artifact_id: str) -> list[str]:
        bit, elf = self.store.artifact_paths(artifact_id)
        script = self._project_root / "firmware" / "scripts" / "program.tcl"
        return [self._xsct, str(script), str(bit), str(elf), str(self._psu_init(board.target_profile))]

    def _post_verify(self, board: BoardProfile, job_id: str) -> None:
        deadline = time.monotonic() + self.verify_timeout_s
        status = self.boards.refresh(board.id)
        while not status.online and time.monotonic() < deadline:
            time.sleep(1)
            status = self.boards.refresh(board.id)
        self.store.add_program_log(
            job_id,
            f"RFCTRL2 verification: state={status.state.value} online={status.online} protocol={status.protocol_version}",
        )
        if not status.online:
            raise ManagementError(f"deployment completed but RFCTRL2 verification failed: {status.message}")

        if board.serial_path:
            self.serial.refresh_board(board.id)
            serial_deadline = time.monotonic() + min(self.verify_timeout_s, 5)
            refreshed = self.store.board(board.id)
            while refreshed.serial_status in {"connecting", "missing"} and time.monotonic() < serial_deadline:
                time.sleep(0.2)
                refreshed = self.store.board(board.id)
            self.store.add_program_log(
                job_id, f"UART verification: path={board.serial_path} state={refreshed.serial_status}"
            )
        else:
            self.store.add_program_log(job_id, "UART verification skipped: no serial path is registered")

    def _run(self, job_id: str) -> None:
        with self._lock:
            job = self.store.update_program_job(job_id, "PREFLIGHT", 0.05)
            emit(self.events, "programming.updated", job)
            try:
                board = self.store.board(job.board_id)
                env = os.environ.copy()
                env["JTAG_CABLE_SERIAL"] = board.jtag_cable_serial
                env["TARGET"] = board.target_profile
                command = self._command(board, job.artifact_id)
                self.store.add_program_log(job_id, "Executing controlled XSCT deployment for registered JTAG cable serial.")
                current = self.store.update_program_job(job_id, "RUNNING", 0.15)
                emit(self.events, "programming.updated", current)
                process = subprocess.Popen(command, cwd=self._project_root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
                assert process.stdout is not None

                def consume_output() -> None:
                    assert process.stdout is not None
                    for line in process.stdout:
                        self.store.add_program_log(job_id, line)
                        emit(self.events, "programming.log", {"job_id": job_id, "line": line.rstrip()})

                reader = threading.Thread(target=consume_output, name=f"rfsoc-program-log-{job_id}", daemon=True)
                reader.start()
                try:
                    return_code = process.wait(timeout=self.timeout_s)
                except subprocess.TimeoutExpired as exc:
                    process.kill()
                    process.wait()
                    raise ManagementError(f"XSCT deployment exceeded {self.timeout_s} seconds") from exc
                finally:
                    reader.join(timeout=5)
                if return_code != 0:
                    raise ManagementError(f"XSCT deployment failed with exit code {process.returncode}")
                self._post_verify(board, job_id)
                completed = self.store.update_program_job(job_id, "SUCCEEDED", 1.0)
                self.store.add_audit("program.succeeded", f"programmed {board.name}", board_id=board.id)
                emit(self.events, "programming.updated", completed)
            except Exception as exc:
                failed = self.store.update_program_job(job_id, "FAILED", 1.0, str(exc))
                self.store.add_program_log(job_id, f"ERROR: {exc}")
                emit(self.events, "programming.updated", failed)
