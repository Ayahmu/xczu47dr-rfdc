from __future__ import annotations

import asyncio
import os
import sys
import threading
import time
import uuid
from dataclasses import replace
from pathlib import Path

SOFTWARE_DIR = Path(__file__).resolve().parents[1]
if str(SOFTWARE_DIR) not in sys.path:
    sys.path.insert(0, str(SOFTWARE_DIR))

import host  # noqa: E402
import waveform_gui_model as gui_model  # noqa: E402

from .models import (
    ActionResponse,
    BoardProfile,
    BoardRole,
    BoardState,
    BoardStatus,
    RunCreateRequest,
    RunEvent,
    RunRecord,
    RunState,
)
from .store import RunStore
from .waveforms import to_waveform_config


DEFAULT_BOARDS = (
    BoardProfile(
        id="board-a",
        name="XCZU47DR A",
        role=BoardRole.MASTER,
        ip="192.168.1.128",
        mac="02:00:00:00:00:01",
        clock_source="onboard",
    ),
    BoardProfile(
        id="board-b",
        name="XCZU47DR B",
        role=BoardRole.FOLLOWER,
        ip="192.168.1.129",
        mac="02:00:00:00:00:02",
        clock_source="master-10mhz",
    ),
)


class EventHub:
    def __init__(self) -> None:
        self._subscribers: set[asyncio.Queue[dict]] = set()
        self._lock = threading.Lock()

    def subscribe(self) -> asyncio.Queue[dict]:
        queue: asyncio.Queue[dict] = asyncio.Queue(maxsize=256)
        with self._lock:
            self._subscribers.add(queue)
        return queue

    def unsubscribe(self, queue: asyncio.Queue[dict]) -> None:
        with self._lock:
            self._subscribers.discard(queue)

    def publish(self, event: dict) -> None:
        with self._lock:
            targets = tuple(self._subscribers)
        for queue in targets:
            try:
                queue.put_nowait(event)
            except asyncio.QueueFull:
                _ = queue.get_nowait()
                queue.put_nowait(event)


class BoardGateway:
    def __init__(self, boards: tuple[BoardProfile, ...] = DEFAULT_BOARDS, profile_provider=None) -> None:
        self._static_boards = boards
        self._profile_provider = profile_provider
        self.simulation = os.environ.get("RFSOC_WEB_SIMULATION", "0") == "1"
        self._statuses: dict[str, BoardStatus] = {}
        self._lock = threading.Lock()
        self._control_locks: dict[str, threading.RLock] = {}
        self._simulated_rfdc: dict[str, dict] = {}
        self._sequence = (time.time_ns() ^ id(self)) & 0xFFFFFFFF or 1

    @property
    def boards(self) -> dict[str, BoardProfile]:
        profiles = tuple(self._profile_provider()) if self._profile_provider else self._static_boards
        with self._lock:
            for board in profiles:
                self._control_locks.setdefault(board.id, threading.RLock())
                if board.id not in self._statuses:
                    self._statuses[board.id] = BoardStatus(
                        board_id=board.id,
                        state=BoardState.IDLE if self.simulation else BoardState.OFFLINE,
                        online=self.simulation,
                        protocol_version=2 if self.simulation else 0,
                        hmc_locked=True if self.simulation else None,
                        rfdc_ready=True if self.simulation else None,
                        rfdc_capabilities=(
                            host.RF2_CAP_PL_RFDC_CONFIG | host.RF2_CAP_RFDC_GET_CONFIG
                            if self.simulation else 0
                        ),
                        rfdc_config_valid_mask=0xFF if self.simulation else 0,
                        message="simulation mode" if self.simulation else "not queried",
                    )
            stale = set(self._statuses) - {board.id for board in profiles}
            for board_id in stale:
                del self._statuses[board_id]
        return {board.id: board for board in profiles}

    def _next_sequence(self) -> int:
        with self._lock:
            sequence = self._sequence
            self._sequence = 1 if self._sequence == 0xFFFFFFFF else self._sequence + 1
        return sequence

    def profile(self, board_id: str) -> BoardProfile:
        try:
            return self.boards[board_id]
        except KeyError as exc:
            raise KeyError(f"unknown board {board_id}") from exc

    def status(self, board_id: str, refresh: bool = True) -> BoardStatus:
        _ = self.boards
        if refresh:
            self.refresh(board_id)
        with self._lock:
            return self._statuses[board_id].model_copy(deep=True)

    def all_statuses(self, refresh: bool = False) -> list[BoardStatus]:
        board_ids = list(self.boards)
        if refresh:
            for board_id in board_ids:
                self.refresh(board_id)
        with self._lock:
            return [self._statuses[board_id].model_copy(deep=True) for board_id in board_ids]

    def refresh(self, board_id: str) -> BoardStatus:
        board = self.profile(board_id)
        if self.simulation:
            simulated = self._simulated_rfdc.get(board_id, {})
            return self._set_status(
                board_id,
                online=True,
                protocol_version=2,
                hmc_locked=True,
                rfdc_ready=True,
                rfdc_capabilities=host.RF2_CAP_PL_RFDC_CONFIG | host.RF2_CAP_RFDC_GET_CONFIG,
                rfdc_config_valid_mask=int(simulated.get("config_valid_mask", 0xFF)),
                rfdc_last_revision=int(simulated.get("revision", 0)),
                playback_armed=bool(simulated.get("playback_armed", False)),
                playback_prepared=bool(simulated.get("playback_prepared", False)),
                playback_running=bool(simulated.get("playback_running", False)),
            )
        try:
            with self._board_control_lock(board_id):
                controller = self._controller(board, timeout_s=0.5)
                try:
                    response = controller.rfctrl2_status(seq=self._next_sequence(), wait_response=True)
                finally:
                    controller.close()
            if int(response.get("status", 1)) != 0:
                raise RuntimeError(f"RFCTRL2 status returned 0x{int(response['status']):04X}")
            decoded = host.parse_rfctrl2_status_payload(response)
            current = self.status(board_id, refresh=False)
            if decoded["running"]:
                state = BoardState.RUNNING
            elif decoded["prepared"] or decoded["armed"]:
                state = BoardState.ARMED
            elif current.state == BoardState.OFFLINE:
                state = BoardState.IDLE
            else:
                state = current.state
            return self._set_status(
                board_id,
                state=state,
                online=True,
                protocol_version=int(response.get("version", 2)),
                rfdc_ready=bool(decoded["rfdc_ready"]),
                rfdc_capabilities=int(decoded["capabilities"]),
                rfdc_config_valid_mask=int(decoded["config_valid_mask"]) & 0xFF,
                rfdc_config_busy=bool(decoded["rfdc_busy"]),
                playback_armed=bool(decoded["armed"]),
                playback_prepared=bool(decoded["prepared"]),
                playback_running=bool(decoded["running"]),
                rfdc_last_revision=int(decoded["last_revision"]),
                rfdc_last_error=int(decoded["last_error"]),
                rfdc_last_error_stage=int(decoded["last_error_stage"]),
                rfdc_last_error_address=int(decoded["last_error_addr"]),
                message=(
                    "RFCTRL2 PREPARED; waiting for TRIGGER"
                    if decoded["prepared"]
                    else "RFCTRL2 ARM accepted; prefetching waveform"
                    if decoded["armed"]
                    else "RFCTRL2 PL RFDC control ready"
                    if int(decoded["capabilities"]) & host.RF2_CAP_PL_RFDC_CONFIG
                    else "RFCTRL2 online; bitstream does not advertise PL RFDC configuration"
                ),
            )
        except OSError as exc:
            return self._set_status(board_id, state=BoardState.OFFLINE, online=False, message=str(exc))
        except (RuntimeError, ValueError, TimeoutError) as exc:
            return self._set_status(board_id, state=BoardState.FAULT, online=False, message=str(exc))

    def mark_state(self, board_id: str, state: BoardState, message: str = "") -> BoardStatus:
        return self._set_status(board_id, state=state, message=message)

    def arm(self, board_id: str, run_token: int, channel_mask: int) -> None:
        board = self.profile(board_id)
        if self.simulation:
            current = self.status(board_id, refresh=False)
            if current.playback_armed or current.playback_running:
                raise RuntimeError("board is already armed; ABORT_MUTE before re-arming")
            valid_mask = int(self._simulated_rfdc.get(board_id, {}).get("config_valid_mask", 0xFF))
            if channel_mask & ~valid_mask:
                raise RuntimeError(
                    f"ARM mask 0x{channel_mask:02X} is not configured by PL (valid 0x{valid_mask:02X})"
                )
            self._simulated_rfdc.setdefault(board_id, {}).update({
                "playback_armed": True,
                "playback_prepared": True,
                "playback_running": False,
            })
            self._set_status(
                board_id,
                state=BoardState.ARMED,
                online=True,
                playback_armed=True,
                playback_prepared=True,
                playback_running=False,
                message="simulated RFCTRL2 PREPARED; waiting for TRIGGER",
            )
            return
        with self._board_control_lock(board_id):
            status = self.refresh(board_id)
            if status.playback_armed or status.playback_running:
                raise RuntimeError("board is already armed; ABORT_MUTE before re-arming")
            if not status.rfdc_capabilities & host.RF2_CAP_PL_RFDC_CONFIG:
                raise RuntimeError("installed bitstream does not support PL RFDC runtime configuration")
            if channel_mask & ~status.rfdc_config_valid_mask:
                raise RuntimeError(
                    f"ARM mask 0x{channel_mask:02X} is not a subset of PL config_valid_mask "
                    f"0x{status.rfdc_config_valid_mask:02X}"
                )
            controller = self._controller(board)
            try:
                response = controller.rfctrl2_arm(run_token, channel_mask=channel_mask, seq=self._next_sequence(), wait_response=True)
                self._require_ok(response, "ARM")
                deadline = time.monotonic() + max(
                    0.1, float(os.environ.get("RFSOC_WEB_ARM_PREPARE_TIMEOUT_S", "15"))
                )
                prepared_status = None
                while time.monotonic() < deadline:
                    status_response = controller.rfctrl2_status(seq=self._next_sequence(), wait_response=True)
                    self._require_ok(status_response, "STATUS after ARM")
                    decoded = host.parse_rfctrl2_status_payload(status_response)
                    prepared_status = decoded
                    self._set_status(
                        board_id,
                        state=BoardState.RUNNING if decoded["running"] else BoardState.ARMED,
                        online=True,
                        protocol_version=2,
                        playback_armed=bool(decoded["armed"]),
                        playback_prepared=bool(decoded["prepared"]),
                        playback_running=bool(decoded["running"]),
                        message=(
                            "RFCTRL2 PREPARED; waiting for TRIGGER"
                            if decoded["prepared"]
                            else "RFCTRL2 ARM accepted; prefetching waveform"
                        ),
                    )
                    if decoded["prepared"]:
                        break
                    time.sleep(0.002)
                if not prepared_status or not prepared_status["prepared"]:
                    try:
                        mute_response = controller.rfctrl2_abort_mute(
                            seq=self._next_sequence(), wait_response=True
                        )
                        self._require_ok(mute_response, "ABORT_MUTE after PREPARE timeout")
                    except Exception:
                        pass
                    raise TimeoutError("ARM accepted but PL did not reach PREPARED before timeout")
            finally:
                controller.close()
        self._set_status(
            board_id,
            state=BoardState.ARMED,
            online=True,
            protocol_version=2,
            playback_armed=True,
            playback_prepared=True,
            playback_running=False,
            message="RFCTRL2 PREPARED; waiting for TRIGGER",
        )

    def sync_epoch(self, board_id: str, epoch: int) -> None:
        board = self.profile(board_id)
        if board.role != BoardRole.MASTER:
            raise ValueError("SYNC_EPOCH may only be sent to the master board")
        if self.simulation:
            self._set_status(board_id, sync_epoch=epoch, online=True, message="simulated master sync epoch")
            return
        with self._board_control_lock(board_id):
            controller = self._controller(board)
            try:
                response = controller.rfctrl2_sync_epoch(epoch, seq=self._next_sequence(), wait_response=True)
            finally:
                controller.close()
        self._require_ok(response, "SYNC_EPOCH")
        self._set_status(board_id, sync_epoch=epoch, online=True, protocol_version=2, message="master sync epoch acknowledged")

    def start_at(self, board_id: str, start_tick: int) -> None:
        board = self.profile(board_id)
        if self.simulation:
            self._set_status(board_id, state=BoardState.RUNNING, online=True, hardware_tick=start_tick, message=f"simulated START_AT {start_tick}")
            return
        with self._board_control_lock(board_id):
            controller = self._controller(board)
            try:
                response = controller.rfctrl2_start_at(start_tick, seq=self._next_sequence(), wait_response=True)
            finally:
                controller.close()
        self._require_ok(response, "START_AT")
        self._set_status(board_id, state=BoardState.RUNNING, online=True, hardware_tick=start_tick, protocol_version=2, message="scheduled start acknowledged")

    def manual_trigger(self, board_id: str) -> None:
        board = self.profile(board_id)
        if self.simulation:
            self._simulated_rfdc.setdefault(board_id, {}).update({
                "playback_armed": True,
                "playback_prepared": False,
                "playback_running": True,
            })
            self._set_status(
                board_id,
                state=BoardState.RUNNING,
                online=True,
                playback_armed=True,
                playback_prepared=False,
                playback_running=True,
                message="simulated manual trigger",
            )
            return
        with self._board_control_lock(board_id):
            status = self.refresh(board_id)
            if not status.playback_prepared:
                raise RuntimeError("RFCTRL2 TRIGGER requires the board to reach PREPARED first")
            controller = self._controller(board)
            try:
                response = controller.rfctrl2_trigger(seq=self._next_sequence(), wait_response=True)
            finally:
                controller.close()
        self._require_ok(response, "TRIGGER")
        self._set_status(
            board_id,
            state=BoardState.RUNNING,
            online=True,
            protocol_version=2,
            playback_armed=True,
            playback_prepared=False,
            playback_running=True,
            message="manual trigger acknowledged; playback gate opened",
        )

    def mute(self, board_id: str) -> None:
        board = self.profile(board_id)
        if self.simulation:
            self._set_status(board_id, state=BoardState.MUTED, online=True, message="simulated mute")
            return
        with self._board_control_lock(board_id):
            controller = self._controller(board)
            try:
                response = controller.rfctrl2_abort_mute(seq=self._next_sequence(), wait_response=True)
            finally:
                controller.close()
        self._require_ok(response, "ABORT_MUTE")
        self._set_status(
            board_id,
            state=BoardState.MUTED,
            online=True,
            playback_armed=False,
            playback_prepared=False,
            playback_running=False,
            message="mute accepted",
        )

    def rfdc_apply(self, board_id: str, channels, revision: int, channel_mask: int) -> dict:
        board = self.profile(board_id)
        ordered = sorted(channels, key=lambda item: item.channel)
        if self.simulation:
            previous = self._simulated_rfdc.get(board_id, {})
            previous_channels = {
                int(item["channel"]): item for item in previous.get("channels", [])
            }
            response_channels = []
            for item in ordered:
                if not channel_mask & (1 << (item.channel - 1)):
                    response_channels.append(previous_channels.get(item.channel, {
                        "channel": item.channel,
                        "nco_hz": 0,
                        "nyquist_zone": 0,
                        "nco_phase_mdeg": 0,
                        "nco_phase_deg": 0.0,
                        "dac_output_current_ua": 0,
                        "dac_output_current_ma": 0.0,
                        "status": 0,
                        "nco_word": 0,
                        "phase_word": 0,
                        "vop_code": 0,
                    }))
                    continue
                nco_word = (int(round(item.nco_hz)) * (1 << 48) // 6_400_000_000) & ((1 << 48) - 1)
                phase_mdeg = host.normalize_rfdc_phase_mdeg(item.nco_phase_deg)
                phase_word = (phase_mdeg * (1 << 17) // 180_000) & ((1 << 18) - 1)
                vop_code = max(0, int((item.dac_output_current_ma * 1000.0 - 1400.0) / 43.75))
                actual_current_ua = int(round(1400.0 + vop_code * 43.75))
                response_channels.append({
                    "channel": item.channel,
                    "nco_hz": int(round(item.nco_hz)),
                    "nyquist_zone": item.nyquist_zone,
                    "nco_phase_mdeg": phase_mdeg,
                    "nco_phase_deg": phase_mdeg / 1000.0,
                    "dac_output_current_ua": actual_current_ua,
                    "dac_output_current_ma": actual_current_ua / 1000.0,
                    "status": 0,
                    "nco_word": nco_word,
                    "phase_word": phase_word,
                    "vop_code": vop_code,
                })
            valid_mask = int(previous.get("config_valid_mask", 0)) | channel_mask
            result = {
                "version": host.RFCTRL2_VERSION,
                "status": host.RF2_STATUS_OK,
                "revision": revision,
                "applied_mask": channel_mask,
                "error_mask": 0,
                "config_valid_mask": valid_mask,
                "failure_stage": 0,
                "failure_address": 0,
                "axi_response": 0,
                "state_flags": host.RF2_STATUS_RFDC_READY,
                "channels": response_channels,
            }
            self._simulated_rfdc[board_id] = result
            self._set_status(
                board_id,
                rfdc_config_valid_mask=valid_mask,
                rfdc_last_revision=revision,
                rfdc_ready=True,
            )
            return result
        with self._board_control_lock(board_id):
            status = self.refresh(board_id)
            if not status.rfdc_capabilities & host.RF2_CAP_PL_RFDC_CONFIG:
                raise RuntimeError("installed bitstream does not support PL RFDC runtime configuration")
            controller = self._controller(board, timeout_s=1.0)
            try:
                return controller.rfctrl2_rfdc_apply(
                    {item.channel: item.nco_hz for item in ordered},
                    {item.channel: item.nyquist_zone for item in ordered},
                    {item.channel: item.nco_phase_deg for item in ordered},
                    {item.channel: item.dac_output_current_ma for item in ordered},
                    revision=revision,
                    channel_mask=channel_mask,
                    seq=self._next_sequence(),
                    wait_response=True,
                    retries=2,
                )
            finally:
                controller.close()

    def rfdc_get_config(self, board_id: str) -> dict:
        board = self.profile(board_id)
        if self.simulation:
            return self._simulated_rfdc.get(board_id, {
                "version": host.RFCTRL2_VERSION,
                "status": host.RF2_STATUS_OK,
                "revision": 0,
                "applied_mask": 0,
                "error_mask": 0,
                "config_valid_mask": 0,
                "failure_stage": 0,
                "failure_address": 0,
                "axi_response": 0,
                "channels": [],
            })
        with self._board_control_lock(board_id):
            status = self.refresh(board_id)
            if not status.rfdc_capabilities & host.RF2_CAP_RFDC_GET_CONFIG:
                raise RuntimeError("installed bitstream does not support PL RFDC configuration readback")
            controller = self._controller(board, timeout_s=1.0)
            try:
                return controller.rfctrl2_rfdc_get_config(
                    seq=self._next_sequence(), wait_response=True, retries=2
                )
            finally:
                controller.close()

    def _board_control_lock(self, board_id: str) -> threading.RLock:
        _ = self.boards
        return self._control_locks[board_id]

    @staticmethod
    def _controller(board: BoardProfile, timeout_s: float = 1.0):
        return host.RFSocController(
            board.ip,
            port=board.port,
            timeout_s=timeout_s,
            transport="udp",
            udp_interface=board.udp_interface,
            udp_source_ip=board.udp_source_ip,
        )

    @staticmethod
    def _require_ok(response: object, operation: str) -> None:
        if not isinstance(response, dict):
            raise RuntimeError(f"RFCTRL2 {operation} returned no response")
        if int(response.get("version", 0)) != host.RFCTRL2_VERSION:
            raise RuntimeError(f"RFCTRL2 {operation} returned an incompatible protocol version")
        if int(response.get("status", 1)) != 0:
            raise RuntimeError(f"RFCTRL2 {operation} failed with status 0x{int(response['status']):04X}")

    def _set_status(self, board_id: str, **changes) -> BoardStatus:
        with self._lock:
            current = self._statuses[board_id]
            self._statuses[board_id] = current.model_copy(update=changes)
            return self._statuses[board_id].model_copy(deep=True)


class RunCoordinator:
    def __init__(self, store: RunStore, boards: BoardGateway, artifacts_root: Path, events: EventHub) -> None:
        self.store = store
        self.boards = boards
        self.artifacts_root = artifacts_root
        self.events = events
        self._group_lock = threading.Lock()
        self._threads: dict[str, threading.Thread] = {}
        self._active_by_board: dict[str, str] = {}
        self.store.recover_orphaned(set())

    def shutdown(self, timeout_s: float = 30.0) -> None:
        """Wait for workers so application-owned storage is not torn down underneath them."""
        deadline = time.monotonic() + timeout_s
        for thread in tuple(self._threads.values()):
            remaining = max(0.0, deadline - time.monotonic())
            thread.join(remaining)

    def create(self, request: RunCreateRequest) -> RunRecord:
        if request.execution_mode != "single" or len(request.jobs) != 1:
            raise ValueError("multi-board synchronization is reserved until hardware qualification is complete")
        for board_id in request.board_ids:
            self.boards.profile(board_id)
        run_id = uuid.uuid4().hex[:12]
        with self._group_lock:
            for board_id in request.board_ids:
                active = self._active_by_board.get(board_id)
                if active:
                    raise RuntimeError(f"run {active} already owns board {board_id}")
            for board_id in request.board_ids:
                self._active_by_board[board_id] = run_id
        artifact_dir = self.artifacts_root / run_id
        try:
            record = self.store.create(run_id, request, artifact_dir)
        except Exception:
            self._release_group(run_id)
            raise
        self._publish_run(record)
        thread = threading.Thread(target=self._execute, args=(run_id,), name=f"rfsoc-run-{run_id}", daemon=True)
        self._threads[run_id] = thread
        thread.start()
        return record

    def arm(self, run_id: str) -> RunRecord:
        record = self._require(run_id)
        if record.state != RunState.READY:
            raise ValueError(f"run {run_id} must be READY before it can be armed")
        if not record.dry_run:
            request = self.store.get_request(run_id)
            try:
                for board_id in record.board_ids:
                    self.boards.arm(board_id, int(run_id, 16), self._channel_mask(request))
            except Exception as exc:
                self._fault(run_id, str(exc))
                raise
        else:
            for board_id in record.board_ids:
                self.boards.mark_state(board_id, BoardState.ARMED, "dry-run armed")
        record = self.store.update(run_id, RunState.ARMED, 1.0)
        self._event(run_id, "single board armed")
        self._publish_run(record)
        return record

    def play_loaded(self, run_id: str) -> RunRecord:
        """Arm and trigger a waveform whose upload task already completed."""
        self.arm_loaded(run_id)
        return self.trigger_loaded(run_id)

    def arm_loaded(self, run_id: str) -> RunRecord:
        record = self._require_loaded(run_id)
        try:
            request = self.store.get_request(run_id)
            channel_mask = self._channel_mask(request)
            for board_id in record.board_ids:
                if record.dry_run:
                    self.boards.mark_state(board_id, BoardState.ARMED, "dry-run loaded waveform armed")
                else:
                    self.boards.arm(board_id, int(run_id, 16), channel_mask)
            self._event(run_id, "loaded waveform armed")
            return record
        except Exception as exc:
            self._event(run_id, str(exc), "error")
            raise

    def trigger_loaded(self, run_id: str) -> RunRecord:
        record = self._require_loaded(run_id)
        try:
            for board_id in record.board_ids:
                if record.dry_run:
                    self.boards.mark_state(board_id, BoardState.RUNNING, "dry-run loaded waveform triggered")
                else:
                    self.boards.manual_trigger(board_id)
            self._event(run_id, "loaded waveform triggered")
            return record
        except Exception as exc:
            self._event(run_id, str(exc), "error")
            raise

    def abort_loaded(self, run_id: str) -> RunRecord:
        record = self._require(run_id)
        if record.state != RunState.DONE or not record.loaded:
            raise ValueError(f"run {run_id} has no completed waveform loaded on the board")
        errors: list[str] = []
        for board_id in record.board_ids:
            try:
                if record.dry_run:
                    self.boards.mark_state(board_id, BoardState.MUTED, "dry-run loaded waveform muted")
                else:
                    self.boards.mute(board_id)
            except Exception as exc:
                errors.append(f"{board_id}: {exc}")
        self._event(run_id, "loaded waveform muted" if not errors else "; ".join(errors), "warning" if errors else "info")
        return record

    def start(self, run_id: str, manual: bool = False) -> RunRecord:
        record = self._require(run_id)
        if record.state != RunState.ARMED:
            raise ValueError(f"run {run_id} must be ARMED before it can start")
        try:
            if record.dry_run:
                for board_id in record.board_ids:
                    self.boards.mark_state(board_id, BoardState.RUNNING, "dry-run single-board trigger")
            else:
                for board_id in record.board_ids:
                    self.boards.manual_trigger(board_id)
        except Exception as exc:
            self._fault(run_id, str(exc))
            raise
        record = self.store.update(run_id, RunState.RUNNING, 1.0)
        self._event(run_id, "single-board trigger accepted")
        self._publish_run(record)
        return record

    def abort(self, run_id: str) -> RunRecord:
        record = self._require(run_id)
        errors: list[str] = []
        if not record.dry_run:
            for board_id in record.board_ids:
                try:
                    self.boards.mute(board_id)
                except Exception as exc:  # best-effort emergency action
                    errors.append(f"{board_id}: {exc}")
        record = self.store.update(run_id, RunState.ABORTED, 1.0, "; ".join(errors))
        self._event(run_id, "abort/mute requested" if not errors else f"abort completed with errors: {'; '.join(errors)}", "warning")
        self._publish_run(record)
        self._release_group(run_id)
        return record

    def _execute(self, run_id: str) -> None:
        try:
            request = self.store.get_request(run_id)
            record = self.store.update(run_id, RunState.GENERATING, 0.05)
            self._event(run_id, "generating waveform artifacts")
            self._publish_run(record)
            for index, job in enumerate(request.jobs, start=1):
                board_id = job.board_id
                board = self.boards.profile(board_id)
                config = to_waveform_config(job.waveform, job.override)
                output_dir = self.artifacts_root / run_id / board_id
                effective_dry_run = request.dry_run or self.boards.simulation
                config = replace(config, output_dir=output_dir, dry_run=effective_dry_run, wait_for_trigger=True)
                connection = gui_model.ConnectionConfig(
                    ip=board.ip,
                    port=board.port,
                    udp_interface=board.udp_interface,
                    udp_source_ip=board.udp_source_ip,
                    timeout_s=5.0,
                    post_upload_sleep_s=0.25,
                )
                if not request.dry_run:
                    record = self.store.update(run_id, RunState.UPLOADING, 0.1 + 0.6 * index / len(request.board_ids))
                    self._event(run_id, f"simulating upload to {board.name}" if self.boards.simulation else f"uploading {board.name}")
                    self._publish_run(record)
                result = gui_model.WaveformController().run(config, connection)
                for line in result.log_lines[-5:]:
                    self._event(run_id, f"{board.id}: {line}")
                if not request.dry_run:
                    self.boards.mark_state(board_id, BoardState.READY, "waveform uploaded")
                    if not self.boards.refresh(board_id).online:
                        raise RuntimeError(f"{board_id}: RFCTRL2 status check failed after waveform upload")
            # Persist the final event before exposing DONE. Once a caller sees DONE,
            # the worker must not perform another SQLite write or teardown can race it.
            if request.dry_run:
                self._event(run_id, "waveform generation validation completed; no data was sent to the board")
                record = self.store.complete_unloaded(run_id)
                self._release_group(run_id)
                self._publish_run(record)
                self.events.publish({"type": "run.done", "data": record.model_dump(mode="json")})
                return

            self._event(run_id, "single board waveform upload completed")
            if request.completion_mode == "one_shot":
                # Keep the run in READY while the automatic pulse is active. The
                # terminal DONE record is published only after mute and lock release.
                record = self.store.complete_loaded(run_id, state=RunState.READY)
                self._publish_run(record)
                for board_id in record.board_ids:
                    if record.dry_run:
                        self.boards.mark_state(board_id, BoardState.ARMED, "dry-run one-shot armed")
                        self.boards.mark_state(board_id, BoardState.RUNNING, "dry-run one-shot triggered")
                    else:
                        self.boards.arm(board_id, int(run_id, 16), self._channel_mask(request))
                        self.boards.manual_trigger(board_id)
                if request.one_shot_duration_ms > 0:
                    time.sleep(request.one_shot_duration_ms / 1000.0)
                for board_id in record.board_ids:
                    if record.dry_run:
                        self.boards.mark_state(board_id, BoardState.MUTED, "dry-run one-shot muted")
                    else:
                        self.boards.mute(board_id)
                self._event(run_id, "one-shot triggered and muted")
                record = self.store.finish_one_shot(run_id)
                self._release_group(run_id)
                self._publish_run(record)
                self.events.publish({"type": "run.done", "data": record.model_dump(mode="json")})
                return
            record = self.store.complete_loaded(run_id)
            self._release_group(run_id)
            self._publish_run(record)
            self.events.publish({"type": "run.done", "data": record.model_dump(mode="json")})
        except Exception as exc:
            self._fault(run_id, str(exc))

    def _fault(self, run_id: str, message: str) -> None:
        record = self.store.update(run_id, RunState.FAULT, 1.0, message)
        try:
            for board_id in record.board_ids:
                self.boards.mark_state(board_id, BoardState.FAULT, message)
        except KeyError:
            pass
        self._event(run_id, message, "error")
        self._publish_run(record)
        self._release_group(run_id)

    def _channel_mask(self, request: RunCreateRequest) -> int:
        job = request.jobs[0]
        channels = job.waveform.manual_channels if job.waveform.mode == "manual" else job.waveform.ezq_channels
        mask = 0
        for channel in channels:
            enabled = job.override.channel_enabled.get(channel.channel, channel.enabled) if job.override else channel.enabled
            if enabled:
                mask |= 1 << (channel.channel - 1)
        return mask

    def _release_group(self, run_id: str) -> None:
        with self._group_lock:
            for board_id, active in tuple(self._active_by_board.items()):
                if active == run_id:
                    del self._active_by_board[board_id]

    def active_run_for_board(self, board_id: str) -> str | None:
        with self._group_lock:
            return self._active_by_board.get(board_id)

    def loaded_run_for_board(self, board_id: str) -> RunRecord | None:
        records = [
            record for record in self.store.list()
            if not record.dry_run and record.loaded and record.state == RunState.DONE and board_id in record.board_ids
        ]
        return records[0] if records else None

    def _event(self, run_id: str, message: str, level: str = "info") -> RunEvent:
        event = self.store.add_event(run_id, message, level)
        self.events.publish({"type": "run.event", "data": event.model_dump(mode="json")})
        return event

    def _publish_run(self, record: RunRecord) -> None:
        self.events.publish({"type": "run.update", "data": record.model_dump(mode="json")})

    def _require(self, run_id: str) -> RunRecord:
        record = self.store.get(run_id)
        if record is None:
            raise KeyError(run_id)
        return record

    def _require_loaded(self, run_id: str) -> RunRecord:
        record = self._require(run_id)
        if record.dry_run or record.state != RunState.DONE or not record.loaded:
            raise ValueError(f"run {run_id} has no completed waveform loaded on the board")
        return record
