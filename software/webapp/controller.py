from __future__ import annotations

import asyncio
import os
import sys
import threading
import time
import uuid
from dataclasses import replace
from pathlib import Path
from typing import Callable

SOFTWARE_DIR = Path(__file__).resolve().parents[1]
if str(SOFTWARE_DIR) not in sys.path:
    sys.path.insert(0, str(SOFTWARE_DIR))

import host  # noqa: E402
import waveform_gui_model as gui_model  # noqa: E402

from .models import (
    ActionResponse,
    BoardProfile,
    BoardState,
    BoardStatus,
    NetworkConfigRequest,
    RunCreateRequest,
    RunEvent,
    RunRecord,
    RunState,
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
                        protocol_version=2 if self.simulation else 0,
                        hmc_locked=True if self.simulation else None,
                        rfdc_ready=True if self.simulation else None,
                        rfdc_capabilities=(
                            host.RF2_CAP_PL_RFDC_CONFIG | host.RF2_CAP_RFDC_GET_CONFIG |
                            host.RF2_CAP_DAC_MTS | host.RF2_CAP_NCO_SYNC
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
        board = self.profile(board_id)
        if self.simulation:
            physical_link = True
            simulated = self._simulated_rfdc.get(board_id, {})
            return self._set_status(
                board_id,
                online=True,
                protocol_version=2,
                hmc_locked=True,
                rfdc_ready=True,
                rfdc_capabilities=(
                    host.RF2_CAP_PL_RFDC_CONFIG | host.RF2_CAP_RFDC_GET_CONFIG |
                    host.RF2_CAP_DAC_MTS | host.RF2_CAP_NCO_SYNC
                ),
                rfdc_config_valid_mask=int(simulated.get("config_valid_mask", 0xFF)),
                dac_mts_required=True,
                dac_mts_ready=True,
                dac_mts_failed=False,
                dac_mts_tile_mask=0xF,
                nco_sync_ready=bool(simulated.get("nco_sync_ready", True)),
                nco_sync_epoch=int(simulated.get("nco_sync_epoch", 1)),
                rfdc_last_revision=int(simulated.get("revision", 0)),
                playback_armed=bool(simulated.get("playback_armed", False)),
                playback_prepared=bool(simulated.get("playback_prepared", False)),
                playback_running=bool(simulated.get("playback_running", False)),
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
            with self._board_control_lock(board_id):
                response = None
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
                        used_bootstrap = address == board.bootstrap_ip
                        responding_address = address
                        break
                    except (OSError, RuntimeError, ValueError, TimeoutError) as exc:
                        last_error = exc
                    finally:
                        controller.close()
                if response is None:
                    raise last_error or TimeoutError("RFCTRL2 status timeout")
            if int(response.get("status", 1)) != 0:
                raise RuntimeError(f"RFCTRL2 status returned 0x{int(response['status']):04X}")
            decoded = host.parse_rfctrl2_status_payload(response)
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
                if int(network_response.get("status", 1)) != host.RF2_STATUS_OK:
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
            current = self.status(board_id, refresh=False)
            if decoded["running"]:
                state = BoardState.RUNNING
            elif decoded["prepared"] or decoded["armed"]:
                state = BoardState.ARMED
            elif current.state == BoardState.OFFLINE:
                state = BoardState.IDLE
            else:
                state = current.state
            apply_status = board.network_apply_status
            apply_error = board.network_apply_error
            if network_configured:
                apply_status = "applied"
                apply_error = ""
                if board.network_apply_status != "applied" or board.network_apply_error:
                    self._persist_network_state(board_id, status=apply_status, error=apply_error)
            return self._set_status(
                board_id,
                state=state,
                online=True,
                protocol_version=int(response.get("version", 2)),
                rfdc_ready=bool(decoded["rfdc_ready"]),
                rfdc_capabilities=int(decoded["capabilities"]),
                rfdc_config_valid_mask=int(decoded["config_valid_mask"]) & 0xFF,
                rfdc_config_busy=bool(decoded["rfdc_busy"]),
                dac_mts_required=bool(decoded.get("dac_mts_required")),
                dac_mts_ready=bool(decoded.get("dac_mts_ready")),
                dac_mts_failed=bool(decoded.get("dac_mts_failed")),
                dac_mts_tile_mask=int(decoded.get("dac_mts_tile_mask", 0)) & 0xF,
                dac_mts_error=int(decoded.get("dac_mts_error", 0)) & 0xFFFF,
                nco_sync_ready=bool(decoded.get("nco_sync_ready")),
                nco_sync_epoch=int(decoded.get("nco_sync_epoch", 0)) & 0xFFFFFFFF,
                playback_armed=bool(decoded["armed"]),
                playback_prepared=bool(decoded["prepared"]),
                playback_running=bool(decoded["running"]),
                **self._playback_debug_status(decoded),
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
                rfdc_last_revision=int(decoded["last_revision"]),
                rfdc_last_error=int(decoded["last_error"]),
                rfdc_last_error_stage=int(decoded["last_error_stage"]),
                rfdc_last_error_address=int(decoded["last_error_addr"]),
                message=(
                    "RFCTRL2 PREPARED; waiting for TRIGGER"
                    if decoded["prepared"]
                    else "RFCTRL2 ARM accepted; prefetching waveform"
                    if decoded["armed"]
                    else "RFCTRL2 online; RFDC tiles are not ready"
                    if not decoded["rfdc_ready"]
                    else "RFCTRL2 PL RFDC control ready"
                    if int(decoded["capabilities"]) & host.RF2_CAP_PL_RFDC_CONFIG
                    else "RFCTRL2 online; bitstream does not advertise PL RFDC configuration"
                ),
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
        except (RuntimeError, ValueError, TimeoutError) as exc:
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
            if not status.dac_mts_required or not status.dac_mts_ready or status.dac_mts_failed:
                raise RuntimeError(
                    "DAC MTS is not ready; refusing ARM "
                    f"(required={int(status.dac_mts_required)}, ready={int(status.dac_mts_ready)}, "
                    f"failed={int(status.dac_mts_failed)}, error=0x{status.dac_mts_error:04X})"
                )
            if not status.nco_sync_ready:
                raise RuntimeError("NCO RTS synchronization has not completed; apply RFDC configuration before ARM")
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
                        **self._playback_debug_status(decoded),
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
                    raise TimeoutError(
                        "ARM accepted but PL did not reach PREPARED before timeout; "
                        f"{self._status_debug(prepared_status)}"
                    )
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

    @staticmethod
    def _trigger_progress_observed(decoded: dict | None) -> bool:
        if not decoded:
            return False
        return bool(decoded.get("running")) or int(decoded.get("play_executor_state", 0)) == 3

    def manual_trigger(self, board_id: str, *, expect_sustained: bool = True) -> None:
        board = self.profile(board_id)
        if self.simulation:
            simulated = self._simulated_rfdc.setdefault(board_id, {})
            simulated.update({
                "playback_armed": True,
                "playback_prepared": False,
                "playback_running": True,
                "trigger_count": int(simulated.get("trigger_count", 0)) + 1,
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
                self._require_ok(response, "TRIGGER")
                deadline = time.monotonic() + max(
                    0.1, float(os.environ.get("RFSOC_WEB_TRIGGER_RUNNING_TIMEOUT_S", "1.0"))
                )
                running_status = None
                trigger_seen = False
                while time.monotonic() < deadline:
                    status_response = controller.rfctrl2_status(seq=self._next_sequence(), wait_response=True)
                    self._require_ok(status_response, "STATUS after TRIGGER")
                    decoded = host.parse_rfctrl2_status_payload(status_response)
                    running_status = decoded
                    trigger_seen = trigger_seen or self._trigger_progress_observed(decoded)
                    self._set_status(
                        board_id,
                        state=BoardState.RUNNING if decoded["running"] else BoardState.ARMED,
                        online=True,
                        protocol_version=2,
                        playback_armed=bool(decoded["armed"]),
                        playback_prepared=bool(decoded["prepared"]),
                        playback_running=bool(decoded["running"]),
                        **self._playback_debug_status(decoded),
                        message=(
                            "RFCTRL2 TRIGGER confirmed; playback gate opened"
                            if decoded["running"]
                            else "RFCTRL2 TRIGGER accepted; waiting for playback gate"
                        ),
                    )
                    if decoded["running"]:
                        break
                    if not expect_sustained and trigger_seen:
                        break
                    time.sleep(0.002)
                if not running_status or (expect_sustained and not running_status["running"]) or (
                    not expect_sustained and not trigger_seen
                ):
                    try:
                        mute_response = controller.rfctrl2_abort_mute(
                            seq=self._next_sequence(), wait_response=True
                        )
                        self._require_ok(mute_response, "ABORT_MUTE after TRIGGER timeout")
                    except Exception:
                        pass
                    raise TimeoutError(
                        "TRIGGER accepted but PL did not reach RUNNING before timeout; "
                        f"{self._status_debug(running_status)}"
                    )
            finally:
                controller.close()
        self._set_status(
            board_id,
            state=BoardState.RUNNING,
            online=True,
            protocol_version=2,
            playback_armed=True,
            playback_prepared=False,
            playback_running=True,
            message="RFCTRL2 TRIGGER confirmed; playback gate opened",
        )

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

    def mute(self, board_id: str) -> None:
        board = self.profile(board_id)
        if self.simulation:
            self._simulated_rfdc.setdefault(board_id, {}).update({
                "playback_armed": False,
                "playback_prepared": False,
                "playback_running": False,
            })
            self._set_status(
                board_id,
                state=BoardState.MUTED,
                online=True,
                playback_armed=False,
                playback_prepared=False,
                playback_running=False,
                message="simulated mute",
            )
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
                if int(response.get("status", 1)) == host.RF2_STATUS_OK:
                    return response
            except (OSError, RuntimeError, ValueError, TimeoutError) as exc:
                last_error = exc
            time.sleep(0.05)
        raise last_error or TimeoutError(f"network identity {address} did not respond")

    def network_get(self, board_id: str, address: str | None = None) -> dict:
        board = self.profile(board_id)
        if self.simulation:
            return {
                "version": host.RFCTRL2_VERSION,
                "status": host.RF2_STATUS_OK,
                "device_uid": board.device_uid or board_id,
                "current_ip": board.active_ip or board.ip,
                "current_mac": board.active_mac or board.mac,
                "bootstrap_ip": board.bootstrap_ip,
                "revision": board.network_revision,
                "port": board.port,
                "capabilities": host.RF2_CAP_NETWORK_CONFIG,
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
                "version": host.RFCTRL2_VERSION,
                "status": host.RF2_STATUS_OK,
                "device_uid": board.device_uid or board.id,
                "current_ip": board.active_ip or board.ip,
                "current_mac": board.active_mac or board.mac,
                "bootstrap_ip": board.bootstrap_ip,
                "revision": board.network_revision,
                "port": board.port,
                "capabilities": host.RF2_CAP_NETWORK_CONFIG,
            }
        return self._network_get_at(board, address)

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
        return host.RFSocController(
            address or board.active_ip or board.ip,
            port=board.port,
            timeout_s=timeout_s,
            transport="udp",
            udp_interface=board.udp_interface,
            udp_source_ip=udp_source_ip_for_address(board, address),
        )

    @staticmethod
    def _require_ok(response: object, operation: str) -> None:
        if not isinstance(response, dict):
            raise RuntimeError(f"RFCTRL2 {operation} returned no response")
        if int(response.get("version", 0)) != host.RFCTRL2_VERSION:
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

    def create(self, request: RunCreateRequest, prepare=None) -> RunRecord:
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
            request = self.store.get_request(run_id)
            expect_sustained = request.playback_mode == "continuous_sine"
            for board_id in record.board_ids:
                if record.dry_run:
                    self.boards.mark_state(board_id, BoardState.RUNNING, "dry-run loaded waveform triggered")
                else:
                    self.boards.manual_trigger(board_id, expect_sustained=expect_sustained)
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

            self._event(run_id, "single board waveform upload completed")
            if request.completion_mode == "one_shot":
                continuous_sine = request.playback_mode == "continuous_sine"
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
                        self.boards.manual_trigger(board_id, expect_sustained=continuous_sine)
                        status = self.boards.status(board_id, refresh=False)
                        self._event(run_id, f"{board_id}: {self._board_playback_summary(status)}")
                if continuous_sine and request.one_shot_duration_ms <= 0:
                    record = self.store.update(run_id, RunState.RUNNING, 1.0)
                    self._event(run_id, "continuous sine playback is running until Stop/Mute is requested")
                    self._publish_run(record)
                    return
                output_duration_s = request.one_shot_duration_ms / 1000.0
                if output_duration_s > 0:
                    time.sleep(output_duration_s)
                for board_id in record.board_ids:
                    if record.dry_run:
                        self.boards.mark_state(board_id, BoardState.MUTED, "dry-run one-shot muted")
                    else:
                        self.boards.mute(board_id)
                if continuous_sine:
                    self._event(run_id, f"continuous sine playback triggered once for {request.one_shot_duration_ms:g} ms and muted")
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
        if mask == 0:
            raise ValueError("at least one waveform channel must be enabled")
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
