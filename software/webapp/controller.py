from __future__ import annotations

import asyncio
import os
import sys
import threading
import time
import uuid
import zlib
from dataclasses import replace
from pathlib import Path
from typing import Callable

SOFTWARE_DIR = Path(__file__).resolve().parents[1]
if str(SOFTWARE_DIR) not in sys.path:
    sys.path.insert(0, str(SOFTWARE_DIR))

import dr47 as driver  # noqa: E402
import waveform_model as gui_model  # noqa: E402

from .models import (
    ActionResponse,
    BoardProfile,
    BoardState,
    BoardStatus,
    NetworkConfigRequest,
    RfdcConfigApplyRequest,
    RunCreateRequest,
    RunEvent,
    RunRecord,
    RunState,
    SyncBoardResult,
    SyncResult,
)
from .store import RunStore
from .network import list_udp_interfaces, udp_path_error, udp_source_ip_for_address
from .waveforms import to_waveform_config


class EventHub:
    def __init__(self) -> None:
        self._subscribers: dict[asyncio.Queue[dict], asyncio.AbstractEventLoop] = {}
        self._lock = threading.Lock()

    def subscribe(self) -> asyncio.Queue[dict]:
        queue: asyncio.Queue[dict] = asyncio.Queue(maxsize=256)
        loop = asyncio.get_running_loop()
        with self._lock:
            self._subscribers[queue] = loop
        return queue

    def unsubscribe(self, queue: asyncio.Queue[dict]) -> None:
        with self._lock:
            self._subscribers.pop(queue, None)

    def publish(self, event: dict) -> None:
        with self._lock:
            targets = tuple(self._subscribers.items())
        for queue, loop in targets:
            if loop.is_closed():
                self.unsubscribe(queue)
                continue

            def deliver(target: asyncio.Queue[dict] = queue) -> None:
                try:
                    target.put_nowait(event)
                except asyncio.QueueFull:
                    try:
                        target.get_nowait()
                    except asyncio.QueueEmpty:
                        pass
                    try:
                        target.put_nowait(event)
                    except asyncio.QueueFull:
                        pass

            loop.call_soon_threadsafe(deliver)


class BoardGateway:
    def __init__(
        self,
        boards: tuple[BoardProfile, ...] = (),
        profile_provider=None,
        network_state_updater: Callable[..., object] | None = None,
    ) -> None:
        self._static_boards = boards
        self._profile_provider = profile_provider
        self._network_state_updater = network_state_updater
        self.simulation = os.environ.get("RFSOC_WEB_SIMULATION", "0") == "1"
        self._statuses: dict[str, BoardStatus] = {}
        self._lock = threading.Lock()
        self._control_locks: dict[str, threading.RLock] = {}
        self._simulated_rfdc: dict[str, dict] = {}
        self._network_recovery_at: dict[str, float] = {}
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
                        protocol_version=driver.RFCTRL2_VERSION if self.simulation else 0,
                        hmc_locked=True if self.simulation else None,
                        rfdc_ready=True if self.simulation else None,
                        rfdc_capabilities=(
                            driver.RF2_CAP_PL_RFDC_CONFIG | driver.RF2_CAP_RFDC_GET_CONFIG |
                            driver.RF2_CAP_DAC_MTS | driver.RF2_CAP_NCO_SYNC
                            if self.simulation else 0
                        ),
                        rfdc_config_valid_mask=0xFF if self.simulation else 0,
                        dac_mts_required=self.simulation,
                        dac_mts_ready=self.simulation,
                        dac_mts_tile_mask=0xF if self.simulation else 0,
                        nco_sync_ready=self.simulation,
                        nco_sync_epoch=1 if self.simulation else 0,
                        physical_link=True if self.simulation else None,
                        udp_interface=board.udp_interface,
                        udp_source_ip=board.udp_source_ip,
                        active_ip=board.active_ip or board.ip,
                        bootstrap_reachable=False,
                        network_configured=board.network_apply_status == "applied",
                        device_uid=board.device_uid,
                        network_revision=board.network_revision,
                        network_apply_status=board.network_apply_status,
                        network_apply_error=board.network_apply_error,
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

    def target_ip(self, board_id: str) -> str:
        board = self.profile(board_id)
        return board.active_ip or board.ip

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
        """Refresh RFDC/network health and the independent waveform snapshot.

        RFCTRL2 STATUS remains the board-health/control-plane source.  Playback
        state is never inferred from its legacy executor fields; it is read from
        WAVECTR0/WAVERSP0 STATUS using the currently observed session (or zero
        when no session has been registered yet).
        """
        board = self.profile(board_id)
        if self.simulation:
            simulated = self._simulated_rfdc.get(board_id, {})
            waveform = simulated.get("waveform", {})
            waveform_response = {
                "status": driver.WAVE_STATUS_OK,
                "session": int(waveform.get("session", 0)),
                "descriptor": int(waveform.get("descriptor", 0)),
                "state": int(waveform.get("state", driver.WAVEFORM_STATE_ID)),
                "state_name": driver.WAVEFORM_STATE_NAMES.get(
                    int(waveform.get("state", driver.WAVEFORM_STATE_ID)), "idle"
                ),
                "current_beat": int(waveform.get("current_beat", 0)),
                "loop_position": int(waveform.get("loop_position", 0)),
                "loop_count": int(waveform.get("loop_count", 0)),
                "fifo_levels": tuple(waveform.get("fifo_levels", (0,) * 8)),
                "error_count": int(waveform.get("error_count", 0)),
                "underflow_count": int(waveform.get("underflow_count", 0)),
                "trigger_seen_count": int(waveform.get("trigger_seen_count", 0)),
                "trigger_dropped_count": int(waveform.get("trigger_dropped_count", 0)),
                "trigger_fire_count": int(waveform.get("trigger_fire_count", 0)),
            }
            waveform_fields = self._waveform_status_fields(waveform_response)
            return self._set_status(
                board_id,
                **waveform_fields,
                online=True,
                protocol_version=driver.RFCTRL2_VERSION,
                hmc_locked=True,
                rfdc_ready=True,
                rfdc_capabilities=(
                    driver.RF2_CAP_PL_RFDC_CONFIG | driver.RF2_CAP_RFDC_GET_CONFIG |
                    driver.RF2_CAP_DAC_MTS | driver.RF2_CAP_NCO_SYNC
                ),
                rfdc_config_valid_mask=int(simulated.get("config_valid_mask", 0xFF)),
                dac_mts_required=True,
                dac_mts_ready=True,
                dac_mts_failed=False,
                dac_mts_tile_mask=0xF,
                nco_sync_ready=bool(simulated.get("nco_sync_ready", True)),
                nco_sync_epoch=int(simulated.get("nco_sync_epoch", 1)),
                rfdc_last_revision=int(simulated.get("revision", 0)),
                physical_link=True,
                udp_interface=board.udp_interface,
                udp_source_ip=board.udp_source_ip,
                active_ip=board.active_ip or board.ip,
                bootstrap_reachable=True,
                network_configured=board.network_apply_status == "applied",
                device_uid=board.device_uid,
                network_revision=board.network_revision,
                network_apply_status=board.network_apply_status,
                network_apply_error=board.network_apply_error,
                message=f"waveform {waveform_response['state_name']}",
            )

        path_error = udp_path_error(board)
        interface_info = next((item for item in list_udp_interfaces() if item.name == board.udp_interface), None)
        physical_link = interface_info.carrier if interface_info else False
        if path_error:
            message = f"{path_error}；控制目标 {board.ip}:{board.port}。"
            if not path_error.startswith("无法自动配置 UDP 网卡"):
                message += "请在板卡档案中选择实际连接的网卡并配置对应源 IP"
            return self._set_status(
                board_id,
                state=BoardState.OFFLINE,
                online=False,
                protocol_version=0,
                rfdc_ready=None,
                rfdc_config_busy=False,
                playback_armed=False,
                playback_prepared=False,
                playback_running=False,
                physical_link=physical_link,
                udp_interface=board.udp_interface,
                udp_source_ip=board.udp_source_ip,
                active_ip=board.active_ip or board.ip,
                message=message,
            )

        try:
            current = self.status(board_id, refresh=False)
            with self._board_control_lock(board_id):
                response = None
                waveform_response = None
                used_bootstrap = False
                responding_address = ""
                last_error: Exception | None = None
                addresses = [board.active_ip or board.ip]
                if board.bootstrap_ip and board.bootstrap_ip not in addresses:
                    addresses.append(board.bootstrap_ip)
                for address in addresses:
                    controller = self._controller(board, timeout_s=0.5, address=address)
                    try:
                        response = controller.rfctrl2_status(seq=self._next_sequence(), wait_response=True)
                        if int(response.get("status", 1)) != driver.RF2_STATUS_OK:
                            raise RuntimeError(
                                f"RFCTRL2 status returned 0x{int(response.get('status', 1)):04X}"
                            )
                        # connect() establishes the driver-side RFCTRL2 session
                        # required by the independent waveform protocol.
                        controller.connect()
                        waveform_response = controller.waveform_status(
                            session=int(current.waveform_session) & 0xFFFFFFFF
                        )
                        self._waveform_state(waveform_response, "STATUS")
                        used_bootstrap = address == board.bootstrap_ip
                        responding_address = address
                        break
                    except (OSError, RuntimeError, ValueError, TimeoutError, driver.DriverError) as exc:
                        last_error = exc
                    finally:
                        controller.close()
                if response is None or waveform_response is None:
                    raise last_error or TimeoutError("board status timeout")

            decoded = driver.parse_rfctrl2_status_payload(response)
            network_response = None
            recovered_ip = board.active_ip or board.ip
            recovered_mac = board.active_mac or board.mac
            recovered_uid = board.device_uid
            recovered_revision = board.network_revision
            desired_ip = board.desired_ip or board.ip
            network_configured = bool(
                responding_address
                and responding_address == desired_ip
                and responding_address != board.bootstrap_ip
                and not responding_address.startswith("169.254.")
            )
            if used_bootstrap:
                network_response = self._network_get_at(board, board.bootstrap_ip)
                if int(network_response.get("status", 1)) != driver.RF2_STATUS_OK:
                    raise RuntimeError(
                        f"NETWORK_GET returned 0x{int(network_response.get('status', 1)):04X}"
                    )
                recovered_uid = str(network_response.get("device_uid") or recovered_uid)
                recovered_revision = int(network_response.get("revision") or recovered_revision)
                recovered_ip = str(network_response.get("current_ip") or recovered_ip)
                recovered_mac = str(network_response.get("current_mac") or recovered_mac)
                self._persist_network_state(
                    board_id,
                    device_uid=recovered_uid,
                    revision=recovered_revision,
                )
                if self._network_identity_needs_recovery(board, network_response):
                    recovered = self._recover_network_identity(board, network_response)
                    if recovered is not None:
                        recovered_ip = str(recovered.get("current_ip") or board.desired_ip)
                        recovered_mac = str(recovered.get("current_mac") or board.desired_mac)
                        recovered_uid = str(recovered.get("device_uid") or recovered_uid)
                        recovered_revision = int(recovered.get("revision") or recovered_revision)
                        network_configured = True
                else:
                    network_configured = recovered_ip != board.bootstrap_ip

            apply_status = board.network_apply_status
            apply_error = board.network_apply_error
            if network_configured:
                apply_status = "applied"
                apply_error = ""
                if board.network_apply_status != "applied" or board.network_apply_error:
                    self._persist_network_state(board_id, status=apply_status, error=apply_error)

            waveform_fields = self._waveform_status_fields(waveform_response)
            state_name = str(waveform_response.get("state_name", "unknown"))
            message = (
                f"waveform {state_name}; RFDC tiles are not ready"
                if not decoded.get("rfdc_ready")
                else f"waveform {state_name}"
            )
            return self._set_status(
                board_id,
                **waveform_fields,
                online=True,
                protocol_version=int(response.get("version", driver.RFCTRL2_VERSION)),
                hmc_locked=bool(decoded.get("hmc_locked", False)),
                rfdc_ready=bool(decoded.get("rfdc_ready")),
                rfdc_capabilities=int(decoded.get("capabilities", 0)),
                rfdc_config_valid_mask=int(decoded.get("config_valid_mask", 0)) & 0xFF,
                rfdc_config_busy=bool(decoded.get("rfdc_busy", False)),
                dac_mts_required=bool(decoded.get("dac_mts_required")),
                dac_mts_ready=bool(decoded.get("dac_mts_ready")),
                dac_mts_failed=bool(decoded.get("dac_mts_failed")),
                dac_mts_tile_mask=int(decoded.get("dac_mts_tile_mask", 0)) & 0xF,
                dac_mts_error=int(decoded.get("dac_mts_error", 0)) & 0xFFFF,
                nco_sync_ready=bool(decoded.get("nco_sync_ready")),
                nco_sync_epoch=int(decoded.get("nco_sync_epoch", 0)) & 0xFFFFFFFF,
                physical_link=physical_link,
                udp_interface=board.udp_interface,
                udp_source_ip=board.udp_source_ip,
                active_ip=recovered_ip,
                bootstrap_reachable=used_bootstrap and not network_configured,
                network_configured=network_configured,
                device_uid=recovered_uid,
                network_revision=recovered_revision,
                network_apply_status=apply_status,
                network_apply_error=apply_error,
                rfdc_last_revision=int(decoded.get("last_revision", 0)),
                rfdc_last_error=int(decoded.get("last_error", 0)),
                rfdc_last_error_stage=int(decoded.get("last_error_stage", 0)),
                rfdc_last_error_address=int(decoded.get("last_error_addr", 0)),
                message=message,
            )
        except OSError as exc:
            return self._set_status(
                board_id,
                state=BoardState.OFFLINE,
                online=False,
                protocol_version=0,
                rfdc_ready=None,
                rfdc_config_busy=False,
                playback_armed=False,
                playback_prepared=False,
                playback_running=False,
                physical_link=physical_link,
                udp_interface=board.udp_interface,
                udp_source_ip=board.udp_source_ip,
                active_ip=board.active_ip or board.ip,
                message=str(exc),
            )
        except (RuntimeError, ValueError, TimeoutError, driver.DriverError) as exc:
            return self._set_status(
                board_id,
                state=BoardState.FAULT,
                online=False,
                protocol_version=0,
                rfdc_ready=None,
                rfdc_config_busy=False,
                playback_armed=False,
                playback_prepared=False,
                playback_running=False,
                physical_link=physical_link,
                udp_interface=board.udp_interface,
                udp_source_ip=board.udp_source_ip,
                active_ip=board.active_ip or board.ip,
                message=str(exc),
            )

    def mark_state(self, board_id: str, state: BoardState, message: str = "") -> BoardStatus:
        return self._set_status(board_id, state=state, message=message)

    def register_waveform_session(self, board_id: str, session: int, descriptor: int = 0) -> None:
        """Register a simulator-side descriptor after host artifact generation.

        Live boards return this identity from COMMIT.  Simulation keeps the same
        session/generation contract so web actions cannot accidentally operate on
        a different uploaded waveform.
        """
        session = int(session) & 0xFFFFFFFF
        if session == 0:
            raise ValueError("waveform session must be non-zero")
        self._simulated_rfdc.setdefault(board_id, {})["waveform"] = {
            "session": session,
            "descriptor": int(descriptor) & 0xFFFFFFFF,
            "state": driver.WAVEFORM_STATE_WAIT_TRIGGER,
            "current_beat": 0,
            "loop_position": 0,
            "loop_count": 1,
            "fifo_levels": (0,) * 8,
            "error_count": 0,
            "underflow_count": 0,
            "trigger_seen_count": 0,
            "trigger_dropped_count": 0,
            "trigger_fire_count": 0,
        }

    @staticmethod
    def _waveform_state(response: object, operation: str) -> str:
        if not isinstance(response, dict):
            raise RuntimeError(f"waveform {operation} returned no response")
        if int(response.get("status", 1)) != driver.WAVE_STATUS_OK:
            raise RuntimeError(
                f"waveform {operation} failed with status 0x{int(response.get('status', 1)):04X}"
                + (f" ({response.get('error_code')})" if response.get("error_code") else "")
            )
        return str(response.get("state_name") or driver.WAVEFORM_STATE_NAMES.get(int(response.get("state", -1)), "unknown"))

    @classmethod
    def _waveform_status_fields(cls, response: dict) -> dict:
        state_name = cls._waveform_state(response, "STATUS")
        # READY retains the committed descriptor for explicit STOP/replay, but
        # it is not an armed playback condition.  Host-side RFDC/network guards
        # must only reject states that can actually consume DAC data or are
        # waiting as an admitted playback.
        armed = state_name in {"prefetch", "wait_trigger", "playing", "draining"}
        prepared = state_name == "wait_trigger"
        running = state_name in {"playing", "draining"}
        board_state = (
            BoardState.RUNNING if running else
            BoardState.ARMED if armed else
            BoardState.READY if state_name in {"ready", "done"} else
            BoardState.FAULT if state_name == "error" else
            BoardState.IDLE
        )
        return {
            "state": board_state,
            "playback_armed": armed,
            "playback_prepared": prepared,
            "playback_running": running,
            "waveform_session": int(response.get("session", 0)),
            "waveform_descriptor": int(response.get("descriptor", 0)),
            "waveform_current_beat": int(response.get("current_beat", 0)),
            "waveform_loop_position": int(response.get("loop_position", 0)),
            "waveform_loop_count": int(response.get("loop_count", 0)),
            "waveform_fifo_levels": [int(value) for value in response.get("fifo_levels", ())],
            "error_count": int(response.get("error_count", 0)),
            "underflow_count": int(response.get("underflow_count", 0)),
            "underflow_mask": 0xFF if int(response.get("underflow_count", 0)) else 0,
            "trigger_seen_count": int(response.get("trigger_seen_count", 0)),
            "trigger_dropped_count": int(response.get("trigger_dropped_count", 0)),
            "trigger_fire_count": int(response.get("trigger_fire_count", 0)),
        }

    def _set_waveform_status(self, board_id: str, response: dict, *, message: str = "") -> BoardStatus:
        state_name = self._waveform_state(response, "STATUS")
        return self._set_status(
            board_id,
            **self._waveform_status_fields(response),
            online=True,
            protocol_version=driver.RFCTRL2_VERSION,
            message=message or f"waveform {state_name}",
        )

    def arm(self, board_id: str, *, session: int) -> None:
        """Validate that COMMIT's prefetch reached a safe trigger point.

        The v2 waveform protocol has no ARM opcode.  COMMIT starts prefetch;
        this method only observes the descriptor identified by ``session``.
        """
        board = self.profile(board_id)
        session = int(session) & 0xFFFFFFFF
        if session == 0:
            raise ValueError("waveform session must be non-zero")
        if self.simulation:
            waveform = self._simulated_rfdc.get(board_id, {}).get("waveform")
            if not waveform or int(waveform["session"]) != session:
                raise RuntimeError(f"{board_id}: waveform session mismatch")
            if int(waveform["state"]) not in (driver.WAVEFORM_STATE_PREFETCH, driver.WAVEFORM_STATE_WAIT_TRIGGER):
                raise RuntimeError(f"{board_id}: waveform is not in PREFETCH/WAIT_TRIGGER")
            self._set_waveform_status(board_id, {
                "status": driver.WAVE_STATUS_OK, "session": session,
                "descriptor": waveform["descriptor"], "state": waveform["state"],
                "state_name": driver.WAVEFORM_STATE_NAMES[waveform["state"]],
            }, message="waveform prefetch ready; waiting for trigger")
            return
        with self._board_control_lock(board_id):
            controller = self._controller(board)
            try:
                controller.connect()
                response = controller.waveform_status(session=session)
                state_name = self._waveform_state(response, "STATUS")
                if state_name not in {"prefetch", "wait_trigger"}:
                    raise RuntimeError(
                        f"{board_id}: waveform session 0x{session:08X} is {state_name}, expected PREFETCH/WAIT_TRIGGER"
                    )
                self._set_waveform_status(board_id, response, message="waveform prefetch ready; waiting for trigger")
            finally:
                controller.close()

    def manual_trigger(self, board_id: str, *, session: int, expect_sustained: bool = True) -> None:
        """Start the committed descriptor through the v2 PLAY command."""
        del expect_sustained  # v2 PLAY is edge-triggered; duration is a descriptor property.
        board = self.profile(board_id)
        session = int(session) & 0xFFFFFFFF
        if session == 0:
            raise ValueError("waveform session must be non-zero")
        if self.simulation:
            waveform = self._simulated_rfdc.get(board_id, {}).get("waveform")
            if not waveform or int(waveform["session"]) != session:
                raise RuntimeError(f"{board_id}: waveform session mismatch")
            if int(waveform["state"]) != driver.WAVEFORM_STATE_WAIT_TRIGGER:
                raise RuntimeError(f"{board_id}: waveform PLAY requires WAIT_TRIGGER")
            waveform["state"] = driver.WAVEFORM_STATE_PLAYING
            waveform["trigger_fire_count"] += 1
            self._set_waveform_status(board_id, {
                "status": driver.WAVE_STATUS_OK, "session": session,
                "descriptor": waveform["descriptor"], "state": waveform["state"],
                "state_name": driver.WAVEFORM_STATE_NAMES[waveform["state"]],
                "trigger_fire_count": waveform["trigger_fire_count"],
            }, message="waveform PLAY accepted")
            return
        with self._board_control_lock(board_id):
            controller = self._controller(board)
            try:
                controller.connect()
                response = controller.play(session=session)
                self._waveform_state(response, "PLAY")
                status_response = controller.waveform_status(session=session)
                state_name = self._waveform_state(status_response, "STATUS")
                if state_name not in {"playing", "draining", "done"}:
                    raise RuntimeError(
                        f"{board_id}: waveform PLAY did not enter PLAYING/DRAINING/DONE (state={state_name})"
                    )
                self._set_waveform_status(board_id, status_response, message="waveform PLAY accepted")
            finally:
                controller.close()

    def mute(self, board_id: str, *, session: int) -> None:
        """Stop playback and return the committed descriptor to READY."""
        board = self.profile(board_id)
        session = int(session) & 0xFFFFFFFF
        if session == 0:
            raise ValueError("waveform session must be non-zero")
        if self.simulation:
            waveform = self._simulated_rfdc.get(board_id, {}).get("waveform")
            if not waveform or int(waveform["session"]) != session:
                raise RuntimeError(f"{board_id}: waveform session mismatch")
            waveform["state"] = driver.WAVEFORM_STATE_READY
            self._set_waveform_status(board_id, {
                "status": driver.WAVE_STATUS_OK, "session": session,
                "descriptor": waveform["descriptor"], "state": waveform["state"],
                "state_name": "ready",
            }, message="waveform STOP accepted")
            return
        with self._board_control_lock(board_id):
            controller = self._controller(board)
            try:
                controller.connect()
                response = controller.stop(session=session)
                self._waveform_state(response, "STOP")
                self._set_waveform_status(board_id, response, message="waveform STOP accepted")
            finally:
                controller.close()

    def abort(self, board_id: str, *, session: int = 0) -> None:
        """Abort a waveform session and clear its descriptor."""
        board = self.profile(board_id)
        session = int(session) & 0xFFFFFFFF
        if self.simulation:
            waveform = self._simulated_rfdc.get(board_id, {}).get("waveform")
            if session and waveform and int(waveform["session"]) != session:
                raise RuntimeError(f"{board_id}: waveform session mismatch")
            self._simulated_rfdc.setdefault(board_id, {}).pop("waveform", None)
            self._set_status(board_id, state=BoardState.IDLE, playback_armed=False, playback_prepared=False, playback_running=False, waveform_session=0, waveform_descriptor=0, message="waveform ABORT accepted")
            return
        with self._board_control_lock(board_id):
            controller = self._controller(board)
            try:
                controller.connect()
                response = controller.abort(session=session)
                self._waveform_state(response, "ABORT")
                self._set_waveform_status(board_id, response, message="waveform ABORT accepted")
            finally:
                controller.close()

    def wait_for_loop_prepared(
        self,
        board_id: str,
        deadline: float,
        expected_cycle_s: float,
    ) -> bool:
        """Wait until PL has refilled the next loop frame and closed its gate."""
        if self.simulation:
            simulated_cycle_s = max(
                expected_cycle_s,
                float(os.environ.get("RFSOC_WEB_SIM_LOOP_CYCLE_S", "0.001")),
            )
            remaining = deadline - time.monotonic()
            if remaining <= simulated_cycle_s:
                if remaining > 0:
                    time.sleep(remaining)
                return False
            time.sleep(simulated_cycle_s)
            current = self.status(board_id, refresh=False)
            if not current.playback_armed:
                raise RuntimeError("board left the RFCTRL2 ARM session while waiting for the next loop frame")
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
                message="simulated loop frame PREPARED; waiting for the next TRIGGER",
            )
            return True

        poll_s = max(0.0001, float(os.environ.get("RFSOC_WEB_LOOP_STATUS_POLL_S", "0.001")))
        while time.monotonic() < deadline:
            status = self.refresh(board_id)
            if status.playback_prepared:
                return True
            if not status.online:
                raise RuntimeError(f"{board_id}: RFCTRL2 went offline while waiting for the next loop frame")
            if not status.playback_armed and not status.playback_running:
                raise RuntimeError(f"{board_id}: PL left the ARM session before the next loop frame was prepared")
            remaining = deadline - time.monotonic()
            if remaining > 0:
                time.sleep(min(poll_s, remaining))
        return False

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
                phase_mdeg = driver.normalize_rfdc_phase_mdeg(item.nco_phase_deg)
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
                "version": driver.RFCTRL2_VERSION,
                "status": driver.RF2_STATUS_OK,
                "revision": revision,
                "applied_mask": channel_mask,
                "error_mask": 0,
                "config_valid_mask": valid_mask,
                "failure_stage": 0,
                "failure_address": 0,
                "axi_response": 0,
                "state_flags": driver.RF2_STATUS_RFDC_READY,
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
            if not status.rfdc_capabilities & driver.RF2_CAP_PL_RFDC_CONFIG:
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
                "version": driver.RFCTRL2_VERSION,
                "status": driver.RF2_STATUS_OK,
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
            if not status.rfdc_capabilities & driver.RF2_CAP_RFDC_GET_CONFIG:
                raise RuntimeError("installed bitstream does not support PL RFDC configuration readback")
            controller = self._controller(board, timeout_s=1.0)
            try:
                return controller.rfctrl2_rfdc_get_config(
                    seq=self._next_sequence(), wait_response=True, retries=2
                )
            finally:
                controller.close()

    @staticmethod
    def _canonical_mac(value: str) -> str:
        return value.replace(":", "").replace("-", "").lower()

    def _persist_network_state(self, board_id: str, **changes) -> None:
        if self._network_state_updater is not None:
            self._network_state_updater(board_id, **changes)

    def _network_identity_needs_recovery(self, board: BoardProfile, response: dict) -> bool:
        desired_ip = board.desired_ip or board.ip
        desired_mac = board.desired_mac or board.mac
        current_ip = str(response.get("current_ip") or "")
        current_mac = str(response.get("current_mac") or "")
        return bool(
            desired_ip
            and desired_mac
            and (
                current_ip != desired_ip
                or self._canonical_mac(current_mac) != self._canonical_mac(desired_mac)
            )
        )

    def _recover_network_identity(self, board: BoardProfile, response: dict) -> dict | None:
        now = time.monotonic()
        if now - self._network_recovery_at.get(board.id, 0.0) < 5.0:
            return None
        self._network_recovery_at[board.id] = now
        desired_ip = board.desired_ip or board.ip
        desired_mac = board.desired_mac or board.mac
        try:
            request = NetworkConfigRequest(
                revision=max(board.network_revision + 1, int(response.get("revision", 0)) + 1),
                ip=desired_ip,
                mac=desired_mac,
                subnet_mask=str(response.get("subnet_mask") or "255.255.255.0"),
                gateway=str(response.get("gateway") or "0.0.0.0"),
                port=int(response.get("port") or board.port),
            )
            self._persist_network_state(
                board.id,
                desired_ip=request.ip,
                desired_mac=request.mac,
                revision=request.revision,
                status="pending",
                error="",
            )
            self.network_apply(board.id, request, address=board.bootstrap_ip)
            self.network_restart(board.id, address=board.bootstrap_ip)
            confirmed = self._wait_network_get(board, request.ip)
            self._persist_network_state(
                board.id,
                active_ip=str(confirmed.get("current_ip") or request.ip),
                active_mac=str(confirmed.get("current_mac") or request.mac),
                device_uid=str(confirmed.get("device_uid") or response.get("device_uid") or ""),
                revision=int(confirmed.get("revision") or request.revision),
                status="applied",
                error="",
            )
            return confirmed
        except Exception as exc:
            self._persist_network_state(board.id, status="failed", error=str(exc))
            return None

    def _network_get_at(self, board: BoardProfile, address: str) -> dict:
        controller = self._controller(board, timeout_s=1.0, address=address)
        try:
            response = controller.rfctrl2_network_get(
                seq=self._next_sequence(), wait_response=True, retries=1
            )
            response["bootstrap_reachable"] = address == board.bootstrap_ip
            return response
        finally:
            controller.close()

    def _wait_network_get(self, board: BoardProfile, address: str, timeout_s: float = 3.0) -> dict:
        deadline = time.monotonic() + timeout_s
        last_error: Exception | None = None
        while time.monotonic() < deadline:
            try:
                response = self._network_get_at(board, address)
                if int(response.get("status", 1)) == driver.RF2_STATUS_OK:
                    return response
            except (OSError, RuntimeError, ValueError, TimeoutError) as exc:
                last_error = exc
            time.sleep(0.05)
        raise last_error or TimeoutError(f"network identity {address} did not respond")

    def network_get(self, board_id: str, address: str | None = None) -> dict:
        board = self.profile(board_id)
        if self.simulation:
            return {
                "version": driver.RFCTRL2_VERSION,
                "status": driver.RF2_STATUS_OK,
                "device_uid": board.device_uid or board_id,
                "current_ip": board.active_ip or board.ip,
                "current_mac": board.active_mac or board.mac,
                "bootstrap_ip": board.bootstrap_ip,
                "revision": board.network_revision,
                "port": board.port,
                "capabilities": driver.RF2_CAP_NETWORK_CONFIG,
                "hmc_done": True,
                "sync_done": True,
            }
        with self._board_control_lock(board_id):
            addresses = [address or board.active_ip or board.ip]
            if address is None and board.bootstrap_ip and board.bootstrap_ip not in addresses:
                addresses.append(board.bootstrap_ip)
            last_error: Exception | None = None
            for target in addresses:
                try:
                    return self._network_get_at(board, target)
                except (OSError, RuntimeError, ValueError, TimeoutError) as exc:
                    last_error = exc
            raise last_error or TimeoutError("NETWORK_GET timeout")

    def network_get_profile(self, board: BoardProfile, address: str) -> dict:
        if self.simulation:
            return {
                "version": driver.RFCTRL2_VERSION,
                "status": driver.RF2_STATUS_OK,
                "device_uid": board.device_uid or board.id,
                "current_ip": board.active_ip or board.ip,
                "current_mac": board.active_mac or board.mac,
                "bootstrap_ip": board.bootstrap_ip,
                "revision": board.network_revision,
                "port": board.port,
                "capabilities": driver.RF2_CAP_NETWORK_CONFIG,
                "hmc_done": True,
                "sync_done": True,
            }
        return self._network_get_at(board, address)

    def _wait_network_flag(
        self,
        board_id: str,
        key: str,
        timeout_s: float,
        poll_s: float,
    ) -> dict:
        deadline = time.monotonic() + timeout_s
        last_error: Exception | None = None
        while time.monotonic() < deadline:
            try:
                response = self.network_get(board_id)
                if response.get(key):
                    return response
                last_error = None
            except (OSError, RuntimeError, ValueError, TimeoutError) as exc:
                last_error = exc
            time.sleep(poll_s)
        detail = f" ({last_error})" if last_error is not None else ""
        raise TimeoutError(f"board {board_id} did not report {key} within {timeout_s:g}s{detail}")

    def _wait_mts_ready(
        self,
        board_id: str,
        timeout_s: float,
        poll_s: float,
    ) -> BoardStatus:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            status = self.status(board_id, refresh=True)
            if status.dac_mts_failed:
                raise RuntimeError(
                    f"board {board_id}: DAC MTS failed error=0x{status.dac_mts_error & 0xFFFF:04X}"
                )
            if status.dac_mts_ready and status.nco_sync_ready:
                return status
            time.sleep(poll_s)
        raise TimeoutError(f"board {board_id} did not reach DAC MTS/NCO ready within {timeout_s:g}s")

    def sync_two_boards(
        self,
        master_board_id: str,
        slave_board_id: str,
        epoch: int,
        timeout_s: float = 60.0,
        poll_s: float = 0.5,
    ) -> SyncResult:
        master = self.profile(master_board_id)
        slave = self.profile(slave_board_id)
        self._wait_network_flag(master_board_id, "hmc_done", timeout_s, poll_s)
        self._wait_network_flag(slave_board_id, "hmc_done", timeout_s, poll_s)
        if not self.simulation:
            controller = self._controller(master, timeout_s=2.0)
            try:
                response = controller.rfctrl2_sync_epoch(
                    int(epoch) & 0xFFFFFFFF, wait_response=True
                )
                self._require_ok(response, "SYNC_EPOCH")
            finally:
                controller.close()
        self._wait_network_flag(master_board_id, "sync_done", timeout_s, poll_s)
        self._wait_network_flag(slave_board_id, "sync_done", timeout_s, poll_s)
        results: list[SyncBoardResult] = []
        for board_id in (master_board_id, slave_board_id):
            status = self._wait_mts_ready(board_id, timeout_s, poll_s)
            results.append(
                SyncBoardResult(
                    board_id=board_id,
                    hmc_done=True,
                    sync_done=True,
                    dac_mts_ready=status.dac_mts_ready,
                    nco_sync_ready=status.nco_sync_ready,
                    dac_mts_tile_mask=status.dac_mts_tile_mask & 0xF,
                    message="ready",
                )
            )
        return SyncResult(
            epoch=int(epoch) & 0xFFFFFFFF,
            boards=results,
            ok=True,
            message=f"synchronized {master.name} (master) and {slave.name} (slave)",
        )

    def network_apply_profile(self, board: BoardProfile, request, address: str) -> dict:
        if self.simulation:
            return self.network_get_profile(board, address) | {
                "revision": request.revision,
                "current_ip": request.ip,
                "current_mac": request.mac,
            }
        controller = self._controller(board, timeout_s=2.0, address=address)
        try:
            return controller.rfctrl2_network_apply(
                request.revision, request.ip, request.mac,
                subnet_mask=request.subnet_mask, gateway=request.gateway,
                port=request.port, seq=self._next_sequence(), wait_response=True, retries=2,
            )
        finally:
            controller.close()

    def network_restart_profile(self, board: BoardProfile, address: str) -> dict:
        if self.simulation:
            return self.network_get_profile(board, address)
        controller = self._controller(board, timeout_s=2.0, address=address)
        try:
            return controller.rfctrl2_network_restart(
                seq=self._next_sequence(), wait_response=True, retries=2
            )
        finally:
            controller.close()

    def network_confirm_profile(self, board: BoardProfile, address: str) -> dict:
        return self._wait_network_get(board, address)

    def network_apply(self, board_id: str, request, address: str | None = None) -> dict:
        board = self.profile(board_id)
        if self.simulation:
            return self.network_get(board_id) | {
                "revision": request.revision,
                "current_ip": request.ip,
                "current_mac": request.mac,
            }
        with self._board_control_lock(board_id):
            status = self.status(board_id, refresh=True)
            if status.playback_armed or status.playback_prepared or status.playback_running:
                raise RuntimeError("network configuration requires playback to be muted and disarmed")
            controller = self._controller(board, timeout_s=2.0, address=address)
            try:
                return controller.rfctrl2_network_apply(
                    request.revision, request.ip, request.mac,
                    subnet_mask=request.subnet_mask, gateway=request.gateway,
                    port=request.port, seq=self._next_sequence(), wait_response=True, retries=2,
                )
            finally:
                controller.close()

    def network_restart(self, board_id: str, address: str | None = None) -> dict:
        board = self.profile(board_id)
        if self.simulation:
            return self.network_get(board_id)
        with self._board_control_lock(board_id):
            controller = self._controller(board, timeout_s=2.0, address=address)
            try:
                return controller.rfctrl2_network_restart(
                    seq=self._next_sequence(), wait_response=True, retries=2
                )
            finally:
                controller.close()

    def network_confirm(self, board_id: str, address: str) -> dict:
        board = self.profile(board_id)
        with self._board_control_lock(board_id):
            return self._wait_network_get(board, address)

    def _board_control_lock(self, board_id: str) -> threading.RLock:
        _ = self.boards
        return self._control_locks[board_id]

    @staticmethod
    def _controller(board: BoardProfile, timeout_s: float = 1.0, address: str | None = None):
        # All live board I/O goes through the distributable driver package.
        return driver.Dr47Device(
            address or board.active_ip or board.ip,
            port=board.port,
            timeout_s=timeout_s,
            udp_interface=board.udp_interface,
            udp_source_ip=udp_source_ip_for_address(board, address),
            retries=2,
        )

    @staticmethod
    def _require_ok(response: object, operation: str) -> None:
        if not isinstance(response, dict):
            raise RuntimeError(f"RFCTRL2 {operation} returned no response")
        if int(response.get("version", 0)) != driver.RFCTRL2_VERSION:
            raise RuntimeError(f"RFCTRL2 {operation} returned an incompatible protocol version")
        if int(response.get("status", 1)) != 0:
            raise RuntimeError(f"RFCTRL2 {operation} failed with status 0x{int(response['status']):04X}")

    @staticmethod
    def _status_debug(decoded: dict | None) -> str:
        if not decoded:
            return "no STATUS response was decoded"
        return (
            f"last_status armed={int(bool(decoded.get('armed')))}, "
            f"prepared={int(bool(decoded.get('prepared')))}, "
            f"running={int(bool(decoded.get('running')))}, "
            f"state_flags=0x{int(decoded.get('state_flags', 0)) & 0xFFFFFFFF:08X}, "
            f"config_valid_mask=0x{int(decoded.get('config_valid_mask', 0)) & 0xFF:02X}, "
            f"play_config_mask=0x{int(decoded.get('play_config_channel_mask', 0)) & 0xFF:02X}, "
            f"fifo_valid_mask=0x{int(decoded.get('play_fifo_valid_mask', 0)) & 0xFF:02X}, "
            f"fifo_ready_mask=0x{int(decoded.get('play_fifo_ready_mask', 0)) & 0xFF:02X}, "
            f"executor_state=0x{int(decoded.get('play_executor_state', 0)) & 0xFF:02X}, "
            f"prefill_ready={int(bool(decoded.get('play_prefill_ready')))}, "
            f"active_valid={int(bool(decoded.get('play_active_valid')))}, "
            f"pending_valid={int(bool(decoded.get('play_pending_valid')))}, "
            f"ddr_read_counter={int(decoded.get('play_ddr_read_counter', 0)) & 0xFFFFFFFF}, "
            f"bad_instr_count={int(decoded.get('play_bad_instr_count', 0)) & 0xFFFFFFFF}, "
            f"mts_required={int(bool(decoded.get('dac_mts_required')))}, "
            f"mts_ready={int(bool(decoded.get('dac_mts_ready')))}, "
            f"mts_failed={int(bool(decoded.get('dac_mts_failed')))}, "
            f"mts_tiles=0x{int(decoded.get('dac_mts_tile_mask', 0)) & 0xF:X}, "
            f"mts_error=0x{int(decoded.get('dac_mts_error', 0)) & 0xFFFF:04X}, "
            f"nco_sync_ready={int(bool(decoded.get('nco_sync_ready')))}, "
            f"nco_sync_epoch={int(decoded.get('nco_sync_epoch', 0)) & 0xFFFFFFFF}, "
            f"last_error=0x{int(decoded.get('last_error', 0)) & 0xFFFFFFFF:08X}, "
            f"last_error_stage=0x{int(decoded.get('last_error_stage', 0)) & 0xFFFFFFFF:08X}, "
            f"last_error_addr=0x{int(decoded.get('last_error_addr', 0)) & 0xFFFFFFFF:08X}"
        )

    @staticmethod
    def _playback_debug_status(decoded: dict) -> dict[str, int | bool]:
        return {
            "play_config_channel_mask": int(decoded.get("play_config_channel_mask", 0)) & 0xFF,
            "play_fifo_valid_mask": int(decoded.get("play_fifo_valid_mask", 0)) & 0xFF,
            "play_fifo_ready_mask": int(decoded.get("play_fifo_ready_mask", 0)) & 0xFF,
            "play_executor_state": int(decoded.get("play_executor_state", 0)) & 0xFF,
            "play_ddr_read_counter": int(decoded.get("play_ddr_read_counter", 0)) & 0xFFFFFFFF,
            "play_bad_instr_count": int(decoded.get("play_bad_instr_count", 0)) & 0xFFFFFFFF,
            "play_prefill_ready": bool(decoded.get("play_prefill_ready", False)),
            "play_active_valid": bool(decoded.get("play_active_valid", False)),
            "play_pending_valid": bool(decoded.get("play_pending_valid", False)),
        }

    def _set_status(self, board_id: str, **changes) -> BoardStatus:
        with self._lock:
            current = self._statuses[board_id]
            self._statuses[board_id] = current.model_copy(update=changes)
            return self._statuses[board_id].model_copy(deep=True)


class RunCoordinator:
    def __init__(
        self,
        store: RunStore,
        boards: BoardGateway,
        artifacts_root: Path,
        events: EventHub,
        rfdc=None,
    ) -> None:
        self.store = store
        self.boards = boards
        self.artifacts_root = artifacts_root
        self.events = events
        self.rfdc = rfdc
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

    def create(self, request: RunCreateRequest, prepare=None) -> RunRecord:
        if request.execution_mode not in ("single", "synchronized"):
            raise ValueError(f"unsupported execution_mode {request.execution_mode}")
        if request.execution_mode == "synchronized" and len(request.jobs) != 2:
            raise ValueError("synchronized runs require exactly two boards")
        if request.execution_mode == "single" and len(request.jobs) != 1:
            raise ValueError("single-board runs require exactly one board")
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
            if prepare is not None:
                prepare(run_id)
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
                for job in request.jobs:
                    self.boards.arm(
                        job.board_id,
                        session=self._waveform_session(record, job.board_id),
                    )
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
            for job in request.jobs:
                channel_mask = self._channel_mask_for_job(job)
                if record.dry_run:
                    self.boards.mark_state(job.board_id, BoardState.ARMED, "dry-run loaded waveform armed")
                else:
                    self.boards.arm(
                        job.board_id,
                        session=self._waveform_session(record, job.board_id),
                    )
            self._event(run_id, "loaded waveform armed" if request.execution_mode == "single" else "synchronized loaded waveform armed")
            return record
        except Exception as exc:
            self._event(run_id, str(exc), "error")
            raise

    def trigger_loaded(self, run_id: str) -> RunRecord:
        record = self._require_loaded(run_id)
        try:
            request = self.store.get_request(run_id)
            expect_sustained = request.playback_mode == "continuous_sine"
            for board_id in self._trigger_board_ids(request):
                if record.dry_run:
                    self.boards.mark_state(board_id, BoardState.RUNNING, "dry-run loaded waveform triggered")
                else:
                    self.boards.manual_trigger(
                        board_id,
                        session=self._waveform_session(record, board_id),
                        expect_sustained=expect_sustained,
                    )
            self._event(run_id, "loaded waveform triggered" if request.execution_mode == "single" else "synchronized master triggered")
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
                    self.boards.mute(
                        board_id,
                        session=self._waveform_session(record, board_id),
                    )
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
                for board_id in self._trigger_board_ids(self.store.get_request(run_id)):
                    self.boards.mark_state(board_id, BoardState.RUNNING, "dry-run trigger")
            else:
                for board_id in self._trigger_board_ids(self.store.get_request(run_id)):
                    self.boards.manual_trigger(
                        board_id,
                        session=self._waveform_session(record, board_id),
                    )
        except Exception as exc:
            self._fault(run_id, str(exc))
            raise
        record = self.store.update(run_id, RunState.RUNNING, 1.0)
        self._event(run_id, "trigger accepted")
        self._publish_run(record)
        return record

    def abort(self, run_id: str) -> RunRecord:
        record = self._require(run_id)
        errors: list[str] = []
        if not record.dry_run:
            for board_id in record.board_ids:
                try:
                    self.boards.mute(
                        board_id,
                        session=self._waveform_session(record, board_id),
                    )
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
            if request.execution_mode == "synchronized":
                master_id = self._sync_master_id(request)
                slave_id = next(job.board_id for job in request.jobs if job.board_id != master_id)
                self._event(run_id, "synchronizing HMC7044 SYSREF and waiting for DAC MTS")
                sync = self.boards.sync_two_boards(master_id, slave_id, int(run_id, 16))
                self._event(run_id, f"two-board synchronization complete: {sync.message}")
            # RFDC_APPLY resets the playback executor state. Apply the RFDC
            # configuration before uploading waveform instructions so ARM can
            # prepare the newly uploaded buffers.
            for job in request.jobs:
                if job.rfdc_config is not None:
                    self._apply_job_rfdc(job)
            for index, job in enumerate(request.jobs, start=1):
                board_id = job.board_id
                board = self.boards.profile(board_id)
                config = to_waveform_config(job.waveform, job.override)
                output_dir = self.artifacts_root / run_id / board_id
                effective_dry_run = request.dry_run or self.boards.simulation
                config = replace(config, output_dir=output_dir, dry_run=effective_dry_run, wait_for_trigger=True)
                connection = gui_model.ConnectionConfig(
                    ip=self.boards.target_ip(board_id),
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
                if not request.dry_run:
                    record = self._record_waveform_session(run_id, board_id, result)
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
                self._release_group(run_id)
                record = self.store.complete_unloaded(run_id)
                self._publish_run(record)
                self.events.publish({"type": "run.done", "data": record.model_dump(mode="json")})
                return

            self._event(run_id, "single board waveform upload completed" if request.execution_mode == "single" else "synchronized waveform upload completed")
            if request.completion_mode == "one_shot":
                continuous_sine = request.playback_mode == "continuous_sine"
                # Keep the run in READY while the automatic pulse is active. The
                # terminal DONE record is published only after mute and lock release.
                record = self.store.complete_loaded(run_id, state=RunState.READY)
                self._publish_run(record)
                for job in request.jobs:
                    board_id = job.board_id
                    if record.dry_run:
                        self.boards.mark_state(board_id, BoardState.ARMED, "dry-run one-shot armed")
                    else:
                        self.boards.arm(
                            board_id,
                            session=self._waveform_session(record, board_id),
                        )
                for board_id in self._trigger_board_ids(request):
                    if record.dry_run:
                        self.boards.mark_state(board_id, BoardState.RUNNING, "dry-run one-shot triggered")
                    else:
                        self.boards.manual_trigger(
                            board_id,
                            session=self._waveform_session(record, board_id),
                            expect_sustained=continuous_sine,
                        )
                        status = self.boards.status(board_id, refresh=False)
                        self._event(run_id, f"{board_id}: {self._board_playback_summary(status)}")
                if continuous_sine and request.one_shot_duration_ms <= 0:
                    record = self.store.update(run_id, RunState.RUNNING, 1.0)
                    self._event(run_id, "continuous playback is running until Stop/Mute is requested")
                    self._publish_run(record)
                    return
                output_duration_s = request.one_shot_duration_ms / 1000.0
                if output_duration_s > 0:
                    time.sleep(output_duration_s)
                for board_id in record.board_ids:
                    if record.dry_run:
                        self.boards.mark_state(board_id, BoardState.MUTED, "dry-run one-shot muted")
                    else:
                        self.boards.mute(
                            board_id,
                            session=self._waveform_session(record, board_id),
                        )
                if continuous_sine:
                    self._event(run_id, f"continuous playback triggered once for {request.one_shot_duration_ms:g} ms and muted")
                elif request.jobs[0].waveform.loop:
                    self._event(run_id, f"loop playback triggered once for {request.one_shot_duration_ms:g} ms and muted")
                else:
                    self._event(run_id, "one-shot triggered and muted")
                self._release_group(run_id)
                record = self.store.finish_one_shot(run_id)
                self._publish_run(record)
                self.events.publish({"type": "run.done", "data": record.model_dump(mode="json")})
                return
            self._release_group(run_id)
            record = self.store.complete_loaded(run_id)
            self._publish_run(record)
            self.events.publish({"type": "run.done", "data": record.model_dump(mode="json")})
        except Exception as exc:
            self._fault(run_id, str(exc))

    def _fault(self, run_id: str, message: str) -> None:
        record = self.store.update(run_id, RunState.FAULT, 1.0, message)
        if not record.dry_run:
            for board_id in record.board_ids:
                try:
                    self.boards.mute(
                        board_id,
                        session=self._waveform_session(record, board_id),
                    )
                except Exception:
                    pass
        try:
            for board_id in record.board_ids:
                self.boards.mark_state(board_id, BoardState.FAULT, message)
        except KeyError:
            pass
        self._event(run_id, message, "error")
        self._publish_run(record)
        self._release_group(run_id)

    @staticmethod
    def _simulation_waveform_identity(run_id: str, board_id: str) -> tuple[int, int]:
        seed = f"{run_id}:{board_id}".encode("utf-8")
        session = zlib.crc32(b"waveform-session:" + seed) & 0xFFFFFFFF
        descriptor = zlib.crc32(b"waveform-descriptor:" + seed) & 0xFFFFFFFF
        return session or 1, descriptor or 1

    def _record_waveform_session(self, run_id: str, board_id: str, result) -> RunRecord:
        """Persist the descriptor session returned by COMMIT before exposing READY.

        Simulation does not transmit UDP, so it creates the same non-zero identity
        contract locally and registers it with the board gateway.  A live upload
        without a COMMIT identity is a protocol failure; never substitute the run
        id because the hardware session is independently allocated by the device.
        """
        record = self._require(run_id)
        upload_result = getattr(result, "upload_result", None)
        if upload_result is not None:
            try:
                session = int(upload_result["session"]) & 0xFFFFFFFF
                descriptor = int(upload_result["descriptor"]) & 0xFFFFFFFF
            except (KeyError, TypeError, ValueError) as exc:
                raise RuntimeError(f"{board_id}: COMMIT did not return a valid waveform session/descriptor") from exc
            if session == 0 or descriptor == 0:
                raise RuntimeError(f"{board_id}: COMMIT returned zero waveform session/descriptor")
        elif self.boards.simulation:
            session, descriptor = self._simulation_waveform_identity(run_id, board_id)
        else:
            raise RuntimeError(f"{board_id}: waveform upload did not return a COMMIT session")

        sessions = dict(record.waveform_sessions)
        previous = sessions.get(board_id)
        if previous is not None and int(previous) != session:
            raise RuntimeError(
                f"{board_id}: waveform session changed during run "
                f"(0x{int(previous) & 0xFFFFFFFF:08X} -> 0x{session:08X})"
            )
        sessions[board_id] = session
        updated = self.store.set_waveform_sessions(run_id, sessions)
        if self.boards.simulation:
            self.boards.register_waveform_session(board_id, session, descriptor)
        return updated

    @staticmethod
    def _waveform_session(record: RunRecord, board_id: str) -> int:
        if board_id not in record.board_ids:
            raise RuntimeError(f"{board_id}: board is not part of run {record.id}")
        try:
            session = int(record.waveform_sessions[board_id]) & 0xFFFFFFFF
        except (KeyError, TypeError, ValueError) as exc:
            raise RuntimeError(f"{board_id}: waveform session is missing for run {record.id}") from exc
        if session == 0:
            raise RuntimeError(f"{board_id}: waveform session is zero for run {record.id}")
        return session

    def _channel_mask(self, request: RunCreateRequest) -> int:
        return self._channel_mask_for_job(request.jobs[0])

    @staticmethod
    def _channel_mask_for_job(job) -> int:
        channels = job.waveform.manual_channels if job.waveform.mode == "manual" else job.waveform.ezq_channels
        mask = 0
        for channel in channels:
            enabled = job.override.channel_enabled.get(channel.channel, channel.enabled) if job.override else channel.enabled
            if enabled:
                mask |= 1 << (channel.channel - 1)
        if mask == 0:
            raise ValueError("at least one waveform channel must be enabled")
        return mask

    def _sync_master_id(self, request: RunCreateRequest) -> str:
        for job in request.jobs:
            profile = self.boards.profile(job.board_id)
            if profile.target_profile in ("custom_xczu47dr", "custom_xczu47dr_master"):
                return job.board_id
        raise ValueError("synchronized run requires one master board (custom_xczu47dr or custom_xczu47dr_master)")

    def _trigger_board_ids(self, request: RunCreateRequest) -> list[str]:
        if request.execution_mode == "synchronized":
            return [self._sync_master_id(request)]
        return list(request.board_ids)

    def _apply_job_rfdc(self, job) -> None:
        if job.rfdc_config is None:
            return
        channels = sorted(job.rfdc_config.channels, key=lambda item: item.channel)
        channel_mask = self._channel_mask_for_job(job)
        if self.rfdc is not None:
            result = self.rfdc.apply(
                job.board_id,
                RfdcConfigApplyRequest(channels=job.rfdc_config.channels, channel_mask=channel_mask),
            )
            if result.apply_status not in ("applied", "partial") or result.error_mask != 0:
                raise RuntimeError(
                    f"{job.board_id}: RFDC_APPLY failed apply_status={result.apply_status} "
                    f"error_mask=0x{result.error_mask & 0xFF:02X}"
                )
            return
        result = self.boards.rfdc_apply(job.board_id, channels, job.rfdc_config.revision, channel_mask)
        status = int(result.get("status", 1))
        error_mask = int(result.get("error_mask", 0))
        if status != driver.RF2_STATUS_OK or error_mask != 0:
            raise RuntimeError(
                f"{job.board_id}: RFDC_APPLY failed status=0x{status:04X} "
                f"error_mask=0x{error_mask & 0xFF:02X}"
            )

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

    @staticmethod
    def _board_playback_summary(status: BoardStatus) -> str:
        return (
            f"armed={int(status.playback_armed)}, prepared={int(status.playback_prepared)}, "
            f"running={int(status.playback_running)}, "
            f"play_config_mask=0x{status.play_config_channel_mask & 0xFF:02X}, "
            f"fifo_valid_mask=0x{status.play_fifo_valid_mask & 0xFF:02X}, "
            f"executor_state=0x{status.play_executor_state & 0xFF:02X}, "
            f"prefill_ready={int(status.play_prefill_ready)}, "
            f"active_valid={int(status.play_active_valid)}, "
            f"pending_valid={int(status.play_pending_valid)}, "
            f"ddr_read_counter={status.play_ddr_read_counter & 0xFFFFFFFF}, "
            f"bad_instr_count={status.play_bad_instr_count & 0xFFFFFFFF}"
        )

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
