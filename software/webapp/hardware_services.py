from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
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
        stable_by_target: dict[str, str] = {}
        stable_dir = Path("/dev/serial/by-id")
        if stable_dir.exists():
            for link in stable_dir.iterdir():
                if link.is_symlink():
                    try:
                        stable_by_target[str(link.resolve())] = str(link)
                    except OSError:
                        continue
        bound = {board.serial_path: board.id for board in self.store.list_boards() if board.serial_path}
        ports: list[SerialPortInfo] = []
        for port in serial.tools.list_ports.comports():
            path = str(port.device)
            stable_path = stable_by_target.get(str(Path(path).resolve()), "")
            info = SerialPortInfo(
                path=path,
                stable_path=stable_path,
                manufacturer=port.manufacturer or "",
                serial_number=port.serial_number or "",
                vendor_id=port.vid and f"{port.vid:04x}" or "",
                product_id=port.pid and f"{port.pid:04x}" or "",
                bound_board_id=bound.get(stable_path) or bound.get(path),
            )
            self.store.upsert_discovery(
                "serial", f"serial:{stable_path or path}", stable_path or path,
                {"path": path, "stable_path": stable_path, "serial_number": info.serial_number,
                 "manufacturer": info.manufacturer, "vendor_id": info.vendor_id, "product_id": info.product_id},
            )
            ports.append(info)
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
    def __init__(self, store: ManagementStore, boards: BoardGateway, serial: SerialService, events: EventHub) -> None:
        self.store = store
        self.boards = boards
        self.serial = serial
        self.events = events
        self.vivado_bin = os.environ.get("RFSOC_WEB_VIVADO_BIN", shutil.which("vivado") or "/tools/Xilinx/Vivado/2024.2/bin/vivado")
        self.hw_server_url = os.environ.get("RFSOC_WEB_HW_SERVER_URL", "localhost:3121")
        self.timeout_s = int(os.environ.get("RFSOC_WEB_VIVADO_TIMEOUT_S", "30"))

    def scan(self) -> dict[str, object]:
        serial_ports = self.serial.discover()
        jtag, vivado_error = self.scan_jtag()
        statuses = self.boards.all_statuses(refresh=True)
        result = {
            "serial": [item.model_dump(mode="json") for item in serial_ports],
            "jtag": jtag,
            "network": [item.model_dump(mode="json") for item in statuses],
            "vivado_error": vivado_error,
        }
        emit(self.events, "inventory.scanned", result)
        return result

    def scan_jtag(self) -> tuple[list[dict[str, str]], str]:
        if not Path(self.vivado_bin).is_file():
            return [], f"Vivado not found: {self.vivado_bin}"
        script = f"""
set status_ok 1
if {{[catch {{
  open_hw_manager
  connect_hw_server -url {{{self.hw_server_url}}}
  foreach target [get_hw_targets *] {{
    set cable ""
    catch {{ set cable [get_property SERIAL_NUMBER $target] }}
    puts "RFWEB_TARGET|$target|$cable"
    if {{[catch {{current_hw_target $target; open_hw_target}} target_error]}} {{
      puts "RFWEB_TARGET_ERROR|$target|$target_error"
      continue
    }}
    foreach device [get_hw_devices *] {{
      set part ""; set programmed "0"; set program_file ""
      catch {{set part [get_property PART $device]}}
      catch {{set programmed [get_property IS_PROGRAMMED $device]}}
      catch {{set program_file [get_property PROGRAM.FILE $device]}}
      puts "RFWEB_DEVICE|$target|$device|$part|$programmed|$program_file"
    }}
  }}
  disconnect_hw_server
}} error_message]}} {{ puts "RFWEB_ERROR|$error_message" }}
exit
"""
        fd, source = tempfile.mkstemp(prefix="rfsoc-web-scan-", suffix=".tcl")
        os.close(fd)
        path = Path(source)
        path.write_text(script, encoding="utf-8")
        try:
            completed = subprocess.run([self.vivado_bin, "-mode", "batch", "-source", str(path)], text=True, capture_output=True, timeout=self.timeout_s, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            return [], str(exc)
        finally:
            path.unlink(missing_ok=True)
        resources: list[dict[str, str]] = []
        errors: list[str] = []
        target_serials: dict[str, str] = {}
        target_errors: dict[str, str] = {}
        device_targets: set[str] = set()
        for line in completed.stdout.splitlines():
            if line.startswith("RFWEB_ERROR|"):
                errors.append(line.split("|", 1)[1])
            elif line.startswith("RFWEB_TARGET_ERROR|"):
                _, target, target_error = (line.split("|", 2) + [""] * 3)[:3]
                target_errors[target] = target_error
                errors.append(f"{target}: {target_error}")
            elif line.startswith("RFWEB_TARGET|"):
                _, target, cable = (line.split("|", 2) + [""] * 3)[:3]
                target_serials[target] = cable
            elif line.startswith("RFWEB_DEVICE|"):
                _, target, device, part, programmed, program_file = (line.split("|", 5) + [""] * 6)[:6]
                device_targets.add(target)
                cable = target_serials.get(target) or self._cable_from_target(target)
                details = {
                    "target": target, "device": device, "part": part, "programmed": programmed,
                    "program_file": program_file, "cable_serial": cable, "availability": "available",
                }
                discovered = self.store.upsert_discovery("jtag", f"jtag:{cable or target}:{device}", cable or target, details)
                resources.append({**details, "state": discovered.state, "board_id": discovered.board_id or ""})
        for target, reported_cable in target_serials.items():
            if target in device_targets:
                continue
            cable = reported_cable or self._cable_from_target(target)
            details = {
                "target": target, "device": "", "part": "", "programmed": "unknown",
                "program_file": "", "cable_serial": cable, "availability": "busy_or_unopened",
                "error": target_errors.get(target, "target could not be opened"),
            }
            discovered = self.store.upsert_discovery("jtag", f"jtag:{cable or target}:target", cable or target, details)
            resources.append({**details, "state": discovered.state, "board_id": discovered.board_id or ""})
        if completed.returncode and not errors:
            errors.append(completed.stderr.strip() or f"Vivado exited with {completed.returncode}")
        return resources, "; ".join(item for item in errors if item)

    @staticmethod
    def _cable_from_target(target: str) -> str:
        return target.rstrip("/").split("/")[-1]


class ProgrammerService:
    TARGET_PARTS = {
        "custom_xczu47dr": "xczu47dr-ffvg1517-2-i",
        "custom_xczu47dr_b": "xczu47dr-ffvg1517-2-i",
        "custom_xczu47dr_bw": "xczu47dr-ffvg1517-2-i",
    }

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
        available = [
            item for item in matches
            if item.get("availability") != "busy_or_unopened" and item.get("part")
        ]
        if not available:
            reason = "; ".join(item.get("error", "") for item in matches if item.get("error"))
            raise ManagementError(
                f"registered JTAG cable serial {board.jtag_cable_serial} is unavailable: "
                f"{reason or error or 'target could not be opened'}"
            )
        expected_part = self.TARGET_PARTS.get(board.target_profile)
        if expected_part and not any(item.get("part", "").lower() == expected_part for item in available):
            found = ", ".join(sorted({item.get("part", "unknown") or "unknown" for item in available}))
            raise ManagementError(f"JTAG device mismatch: expected {expected_part}, found {found}")

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
