from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import os
import shutil
import uuid
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from pathlib import Path

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Request, Response, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

from .controller import BoardGateway, EventHub, RunCoordinator
from .hardware_services import DiscoveryService, ProgrammerService, SerialService, emit
from .management import ManagementError, ManagementStore, PermissionError
from .performance import PerformanceService, PerformanceStore
from .rfdc import RfdcConfigService
from .models import (
    ActionResponse,
    ArtifactRecord,
    AuditEvent,
    BoardPreflight,
    BoardProfile,
    BoardStatus,
    BoardUpdateRequest,
    BoardRfdcConfig,
    DiscoveryResource,
    LoginRequest,
    PreviewRequest,
    PreviewResponse,
    PreflightCheck,
    ProgramCreateRequest,
    ProgramJob,
    PerformancePointRecord,
    PerformanceTestCreateRequest,
    PerformanceTestRecord,
    RfdcConfigApplyRequest,
    RunCreateRequest,
    RunEvent,
    RunRecord,
    SerialBindingRequest,
    SerialLogLine,
    SerialPortInfo,
    SessionResponse,
    UserCreateRequest,
    UserRecord,
    UserRole,
    UserUpdateRequest,
)
from .store import RunStore
from .waveforms import preview_waveforms


STATIC_DIR = Path(__file__).resolve().parents[1] / "webui" / "dist"
SESSION_COOKIE = "rfsoc_web_session"
ARTIFACT_MAX_BYTES = int(os.environ.get("RFSOC_WEB_ARTIFACT_MAX_BYTES", str(1024 * 1024 * 1024)))
TARGET_PROFILES = {"custom_xczu47dr", "custom_xczu47dr_b", "custom_xczu47dr_bw"}


def runtime_root() -> Path:
    default = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "xczu47dr-rfdc"
    return Path(os.environ.get("RFSOC_WEB_RUNTIME_DIR", default))


class AppServices:
    def __init__(self) -> None:
        root = runtime_root()
        self.root = root
        self.events = EventHub()
        self.store = RunStore(root / "rfsoc_web.sqlite3")
        self.management = ManagementStore(root / "rfsoc_web.sqlite3")
        self.boards = BoardGateway(profile_provider=self.management.list_boards)
        self.runs = RunCoordinator(self.store, self.boards, root / "runs", self.events)
        self.serial = SerialService(self.management, self.events)
        self.rfdc = RfdcConfigService(self.management, self.boards, self.serial, self.events)
        self.performance = PerformanceService(
            PerformanceStore(root / "rfsoc_web.sqlite3"), self.management, self.runs, self.rfdc, self.events
        )
        self.discovery = DiscoveryService(self.management, self.boards, self.serial, self.events)
        self.programmer = ProgrammerService(
            self.management, self.boards, self.runs, self.events, self.discovery, self.serial
        )


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.services = AppServices()
    app.state.services.serial.start()
    try:
        yield
    finally:
        app.state.services.performance.shutdown()
        app.state.services.runs.shutdown()
        app.state.services.serial.stop()


app = FastAPI(title="XCZU47DR RFDC Control", version="0.2.0", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173", "http://127.0.0.1:5173"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def services() -> AppServices:
    return app.state.services


def http_error(error: Exception) -> HTTPException:
    if isinstance(error, HTTPException):
        return error
    if isinstance(error, PermissionError):
        return HTTPException(403, str(error))
    if isinstance(error, KeyError):
        return HTTPException(404, str(error))
    if isinstance(error, (ManagementError, ValueError, RuntimeError)):
        return HTTPException(409, str(error))
    return HTTPException(500, "internal control service error")


def current_user(request: Request) -> tuple[UserRecord, str]:
    user, csrf = services().management.session_user(request.cookies.get(SESSION_COOKIE))
    if user is None or csrf is None:
        raise HTTPException(401, "login required")
    return user, csrf


def require_user(request: Request) -> UserRecord:
    return current_user(request)[0]


def require_mutation_user(request: Request, x_csrf_token: str | None = Header(default=None)) -> UserRecord:
    user, csrf = current_user(request)
    if not x_csrf_token or not hmac.compare_digest(x_csrf_token, csrf):
        raise HTTPException(403, "invalid CSRF token")
    return user


def require_admin(user: UserRecord = Depends(require_mutation_user)) -> UserRecord:
    if user.role != UserRole.ADMIN:
        raise HTTPException(403, "administrator role required")
    return user


def require_admin_read(user: UserRecord = Depends(require_user)) -> UserRecord:
    if user.role != UserRole.ADMIN:
        raise HTTPException(403, "administrator role required")
    return user


def publish_inventory(board: BoardProfile) -> None:
    emit(services().events, "inventory.updated", board)


@app.get("/api/health", response_model=ActionResponse)
def health() -> ActionResponse:
    return ActionResponse(ok=True, message="XCZU47DR control service is running")


@app.post("/api/auth/login", response_model=SessionResponse)
def login(request: LoginRequest, response: Response) -> SessionResponse:
    user = services().management.authenticate(request.username, request.password)
    if user is None:
        raise HTTPException(401, "invalid username or password")
    token, csrf = services().management.create_session(user)
    response.set_cookie(
        SESSION_COOKIE, token, httponly=True, samesite="strict", secure=os.environ.get("RFSOC_WEB_COOKIE_SECURE", "0") == "1",
        max_age=14 * 24 * 3600, path="/",
    )
    services().management.add_audit("auth.login", f"{user.username} logged in", user.id)
    return SessionResponse(user=user, csrf_token=csrf)


@app.post("/api/auth/logout", response_model=ActionResponse)
def logout(request: Request, response: Response, user: UserRecord = Depends(require_mutation_user)) -> ActionResponse:
    services().management.delete_session(request.cookies.get(SESSION_COOKIE))
    response.delete_cookie(SESSION_COOKIE, path="/")
    services().management.add_audit("auth.logout", f"{user.username} logged out", user.id)
    return ActionResponse(ok=True, message="logged out")


@app.get("/api/auth/me", response_model=SessionResponse)
def me(request: Request) -> SessionResponse:
    user, csrf = services().management.session_user(request.cookies.get(SESSION_COOKIE))
    return SessionResponse(user=user, csrf_token=csrf)


@app.get("/api/admin/users", response_model=list[UserRecord])
def list_users(_user: UserRecord = Depends(require_admin_read)) -> list[UserRecord]:
    return services().management.list_users()


@app.post("/api/admin/users", response_model=UserRecord, status_code=201)
def create_user(request: UserCreateRequest, actor: UserRecord = Depends(require_admin)) -> UserRecord:
    try:
        created = services().management.create_user(request)
        services().management.add_audit("user.created", f"{actor.username} created {created.username}", actor.id)
        return created
    except Exception as exc:
        raise http_error(exc) from exc


@app.patch("/api/admin/users/{user_id}", response_model=UserRecord)
def update_user(user_id: int, request: UserUpdateRequest, actor: UserRecord = Depends(require_admin)) -> UserRecord:
    if user_id == actor.id and not request.enabled:
        raise HTTPException(409, "cannot disable the current administrator")
    try:
        updated = services().management.update_user(user_id, request)
        services().management.add_audit("user.updated", f"{actor.username} updated {updated.username}", actor.id)
        return updated
    except Exception as exc:
        raise http_error(exc) from exc


@app.get("/api/boards", response_model=list[BoardProfile])
def boards(_user: UserRecord = Depends(require_user)) -> list[BoardProfile]:
    return services().management.list_boards()


@app.get("/api/boards/status", response_model=list[BoardStatus])
def board_statuses(refresh: bool = False, _user: UserRecord = Depends(require_user)) -> list[BoardStatus]:
    return services().boards.all_statuses(refresh=refresh)


@app.get("/api/boards/{board_id}/status", response_model=BoardStatus)
def board_status(board_id: str, refresh: bool = True, _user: UserRecord = Depends(require_user)) -> BoardStatus:
    try:
        return services().boards.status(board_id, refresh=refresh)
    except KeyError as exc:
        raise HTTPException(404, str(exc)) from exc


@app.get("/api/boards/{board_id}/preflight", response_model=BoardPreflight)
def board_preflight(board_id: str, artifact_id: str | None = None, refresh: bool = True,
                    user: UserRecord = Depends(require_user)) -> BoardPreflight:
    try:
        board = services().management.board(board_id)
        status = services().boards.status(board_id, refresh=refresh)
        discovered = [item for item in services().management.discoveries() if item.board_id == board_id]
        active_run = services().runs.active_run_for_board(board_id)
        checks: list[PreflightCheck] = []

        def add(key: str, label: str, state: str, message: str) -> None:
            checks.append(PreflightCheck(key=key, label=label, state=state, message=message))

        add("enabled", "板卡档案", "pass" if board.enabled else "fail", "已启用" if board.enabled else "板卡已禁用")
        add("network", "RFCTRL2 网络", "pass" if status.online else "fail", status.message or ("在线" if status.online else "离线"))
        protocol_ok = status.online and status.protocol_version == 2
        add("protocol", "控制协议", "pass" if protocol_ok else "fail", f"RFCTRL{status.protocol_version}" if status.protocol_version else "未检测到 RFCTRL2")
        add("hmc", "HMC 时钟", "pass" if status.hmc_locked is True else "fail" if status.hmc_locked is False else "warning",
            "LOCKED" if status.hmc_locked is True else "UNLOCKED" if status.hmc_locked is False else "固件未返回锁定状态")
        add("rfdc", "RFDC 初始化", "pass" if status.rfdc_ready is True else "fail" if status.rfdc_ready is False else "warning",
            "READY" if status.rfdc_ready is True else "NOT READY" if status.rfdc_ready is False else "固件未返回初始化状态")

        if not board.serial_path:
            add("uart", "只读 UART", "warning", "未绑定稳定串口路径")
        else:
            serial_ok = board.serial_status == "open"
            add("uart", "只读 UART", "pass" if serial_ok else "fail", f"{board.serial_path} · {board.serial_status}")

        jtag = [item for item in discovered if item.kind == "jtag"]
        if not board.jtag_cable_serial:
            add("jtag", "JTAG 映射", "warning", "未登记 cable serial；不影响已部署板卡的单板发波")
        elif jtag:
            part = str(jtag[0].details.get("part", "unknown"))
            add("jtag", "JTAG 映射", "pass", f"{board.jtag_cable_serial} · {part}")
        else:
            add("jtag", "JTAG 映射", "warning", f"已登记 {board.jtag_cable_serial}，最近扫描未发现")

        if board.lease is None:
            add("lease", "使用权", "warning", "当前空闲；真实发波前需要申请")
            owns_lease = False
        elif board.lease.user_id == user.id:
            add("lease", "使用权", "pass", f"当前用户 {user.username} 已持有")
            owns_lease = True
        else:
            add("lease", "使用权", "fail", f"{board.lease.username} 正在使用")
            owns_lease = False

        add("run", "运行锁", "fail" if active_run else "pass", f"任务 {active_run} 正在占用" if active_run else "无活动波形任务")
        add("sync", "同步档案（预留）", "info", f"{board.sync_group or '未分组'} · {board.role.value}；单板模式不校验同步拓扑")

        artifact_ok = True
        if artifact_id:
            artifact = services().management.artifact(artifact_id)
            artifact_ok = artifact.target_profile == board.target_profile
            add("artifact", "烧写发布兼容性", "pass" if artifact_ok else "fail",
                f"{artifact.label} · {artifact.target_profile}" + ("" if artifact_ok else f"，板卡要求 {board.target_profile}"))

        recent_fault = next((item for item in services().store.list() if board_id in item.board_ids and item.state.value == "FAULT"), None)
        add("fault", "最近故障", "warning" if recent_fault else "pass",
            f"{recent_fault.name}: {recent_fault.error or '任务故障'}" if recent_fault else "最近记录中没有故障")

        can_start = board.enabled and status.online and protocol_ok and status.hmc_locked is not False \
            and status.rfdc_ready is not False and owns_lease and active_run is None and artifact_ok
        return BoardPreflight(board_id=board_id, can_start_live=can_start, checks=checks, checked_at=datetime.now(UTC).isoformat())
    except Exception as exc:
        raise http_error(exc) from exc


@app.post("/api/boards/{board_id}/lease", response_model=BoardProfile)
def lease_board(board_id: str, user: UserRecord = Depends(require_mutation_user)) -> BoardProfile:
    try:
        board = services().management.lease_board(board_id, user)
        publish_inventory(board)
        return board
    except Exception as exc:
        raise http_error(exc) from exc


@app.post("/api/boards/{board_id}/release", response_model=BoardProfile)
def release_board(board_id: str, user: UserRecord = Depends(require_mutation_user)) -> BoardProfile:
    try:
        board = services().management.release_board(board_id, user)
        publish_inventory(board)
        return board
    except Exception as exc:
        raise http_error(exc) from exc


@app.post("/api/admin/boards/{board_id}/force-release", response_model=BoardProfile)
def force_release_board(board_id: str, actor: UserRecord = Depends(require_admin)) -> BoardProfile:
    try:
        active = services().runs.active_run_for_board(board_id)
        if active:
            services().runs.abort(active)
        board = services().management.release_board(board_id, actor, force=True)
        publish_inventory(board)
        return board
    except Exception as exc:
        raise http_error(exc) from exc


@app.post("/api/admin/boards", response_model=BoardProfile, status_code=201)
def add_board(request: BoardUpdateRequest, actor: UserRecord = Depends(require_admin)) -> BoardProfile:
    try:
        board = services().management.add_board(request)
        services().serial.refresh_board(board.id)
        services().management.add_audit("board.created", f"{actor.username} registered {board.name}", actor.id, board.id)
        publish_inventory(board)
        return board
    except Exception as exc:
        raise http_error(exc) from exc


@app.patch("/api/admin/boards/{board_id}", response_model=BoardProfile)
def update_board(board_id: str, request: BoardUpdateRequest, actor: UserRecord = Depends(require_admin)) -> BoardProfile:
    try:
        board = services().management.update_board(board_id, request)
        services().serial.refresh_board(board.id)
        services().management.add_audit("board.updated", f"{actor.username} updated {board.name}", actor.id, board.id)
        publish_inventory(board)
        return board
    except Exception as exc:
        raise http_error(exc) from exc


@app.post("/api/admin/inventory/scan", include_in_schema=False)
@app.post("/api/admin/discovery/scan")
def scan_inventory(actor: UserRecord = Depends(require_admin)) -> dict[str, object]:
    try:
        result = services().discovery.scan()
        services().management.add_audit("inventory.scanned", f"{actor.username} scanned hardware inventory", actor.id)
        return result
    except Exception as exc:
        raise http_error(exc) from exc


@app.get("/api/discovery", response_model=list[DiscoveryResource])
def discoveries(_user: UserRecord = Depends(require_user)) -> list[DiscoveryResource]:
    return services().management.discoveries()


@app.get("/api/serial/ports", response_model=list[SerialPortInfo])
def serial_ports(_user: UserRecord = Depends(require_user)) -> list[SerialPortInfo]:
    try:
        return services().serial.discover()
    except Exception as exc:
        raise http_error(exc) from exc


@app.get("/api/serial/{board_id}/logs", response_model=list[SerialLogLine])
def serial_logs(board_id: str, _user: UserRecord = Depends(require_user)) -> list[SerialLogLine]:
    try:
        services().management.board(board_id)
        return services().management.serial_logs(board_id)
    except Exception as exc:
        raise http_error(exc) from exc


@app.post("/api/admin/boards/{board_id}/serial", response_model=BoardProfile)
def bind_serial(board_id: str, request: SerialBindingRequest, actor: UserRecord = Depends(require_admin)) -> BoardProfile:
    if not request.path.startswith("/dev/"):
        raise HTTPException(422, "serial path must be under /dev")
    try:
        board = services().management.set_serial_binding(board_id, request.path, request.baud_rate)
        services().serial.refresh_board(board_id)
        services().management.add_audit("serial.bound", f"{actor.username} bound {request.path}", actor.id, board_id)
        publish_inventory(board)
        return board
    except Exception as exc:
        raise http_error(exc) from exc


@app.post("/api/waveforms/preview", response_model=PreviewResponse)
def preview(request: PreviewRequest, _user: UserRecord = Depends(require_user)) -> PreviewResponse:
    try:
        return preview_waveforms(request.waveform, request.override, request.fft_channel)
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc


@app.post("/api/runs", response_model=RunRecord, status_code=202)
def create_run(request: RunCreateRequest, user: UserRecord = Depends(require_mutation_user)) -> RunRecord:
    try:
        job = request.jobs[0]
        if not request.dry_run:
            services().management.require_lease(user, job.board_id)
            if job.rfdc_config is not None:
                if job.rfdc_config.board_id != job.board_id:
                    raise ValueError("RFDC configuration board_id does not match the waveform board")
                if services().runs.active_run_for_board(job.board_id):
                    raise RuntimeError(f"board {job.board_id} has an active waveform task")
                waveform_channels = (
                    job.waveform.manual_channels
                    if job.waveform.mode == "manual"
                    else job.waveform.ezq_channels
                )
                channel_mask = sum(
                    1 << (channel.channel - 1)
                    for channel in waveform_channels
                    if channel.enabled
                )
                services().rfdc.apply(job.board_id, RfdcConfigApplyRequest(
                    channels=job.rfdc_config.channels,
                    channel_mask=channel_mask,
                ))
        record = services().runs.create(request)
        services().management.set_run_owner(record.id, user)
        services().management.add_audit("run.created", f"{user.username} created single-board run {record.name}", user.id, job.board_id)
        return record
    except Exception as exc:
        raise http_error(exc) from exc


@app.get("/api/runs", response_model=list[RunRecord])
def list_runs(_user: UserRecord = Depends(require_user)) -> list[RunRecord]:
    return services().store.list()


@app.get("/api/runs/{run_id}", response_model=RunRecord)
def get_run(run_id: str, _user: UserRecord = Depends(require_user)) -> RunRecord:
    record = services().store.get(run_id)
    if record is None:
        raise HTTPException(404, f"unknown run {run_id}")
    return record


@app.get("/api/runs/{run_id}/events", response_model=list[RunEvent])
def run_events(run_id: str, _user: UserRecord = Depends(require_user)) -> list[RunEvent]:
    if services().store.get(run_id) is None:
        raise HTTPException(404, f"unknown run {run_id}")
    return services().store.events(run_id)


def _loaded_run_for_board(board_id: str) -> RunRecord:
    record = services().runs.loaded_run_for_board(board_id)
    if record is None:
        raise HTTPException(404, f"no completed waveform is loaded on board {board_id}")
    return record


def _check_run_control(record: RunRecord, user: UserRecord) -> None:
    if not services().management.can_manage_run(record.id, user):
        raise PermissionError("only the run owner may control this waveform")
    if not record.dry_run:
        services().management.require_lease(user, record.board_ids[0])


@app.post("/api/runs/{run_id}/play", response_model=RunRecord)
def play_run(run_id: str, user: UserRecord = Depends(require_mutation_user)) -> RunRecord:
    try:
        record = services().store.get(run_id)
        if record is None:
            raise KeyError(run_id)
        _check_run_control(record, user)
        return services().runs.play_loaded(run_id)
    except Exception as exc:
        raise http_error(exc) from exc


@app.get("/api/boards/{board_id}/loaded-waveform", response_model=RunRecord | None)
def loaded_waveform(board_id: str, _user: UserRecord = Depends(require_user)) -> RunRecord | None:
    try:
        services().management.board(board_id)
        return services().runs.loaded_run_for_board(board_id)
    except Exception as exc:
        raise http_error(exc) from exc


def board_loaded_action(board_id: str, action: str, user: UserRecord) -> RunRecord:
    try:
        record = _loaded_run_for_board(board_id)
        _check_run_control(record, user)
        if action == "arm":
            return services().runs.arm_loaded(record.id)
        if action == "trigger":
            return services().runs.trigger_loaded(record.id)
        if action == "abort":
            return services().runs.abort_loaded(record.id)
    except Exception as exc:
        raise http_error(exc) from exc
    raise HTTPException(404, f"unknown board action {action}")


@app.post("/api/boards/{board_id}/arm", response_model=RunRecord)
def arm_board(board_id: str, user: UserRecord = Depends(require_mutation_user)) -> RunRecord:
    return board_loaded_action(board_id, "arm", user)


@app.post("/api/boards/{board_id}/trigger", response_model=RunRecord)
def trigger_board(board_id: str, user: UserRecord = Depends(require_mutation_user)) -> RunRecord:
    return board_loaded_action(board_id, "trigger", user)


@app.post("/api/boards/{board_id}/abort", response_model=RunRecord)
def abort_board(board_id: str, user: UserRecord = Depends(require_mutation_user)) -> RunRecord:
    return board_loaded_action(board_id, "abort", user)


@app.get("/api/boards/{board_id}/rfdc-config", response_model=BoardRfdcConfig)
def get_rfdc_config(
    board_id: str,
    refresh: bool = False,
    _user: UserRecord = Depends(require_user),
) -> BoardRfdcConfig:
    try:
        return services().rfdc.get(board_id, refresh=refresh)
    except Exception as exc:
        raise http_error(exc) from exc


@app.post("/api/boards/{board_id}/rfdc-config/apply", response_model=BoardRfdcConfig)
def apply_rfdc_config(
    board_id: str,
    request: RfdcConfigApplyRequest,
    user: UserRecord = Depends(require_mutation_user),
) -> BoardRfdcConfig:
    try:
        services().management.require_lease(user, board_id)
        if services().runs.active_run_for_board(board_id):
            raise RuntimeError(f"board {board_id} has an active waveform task")
        result = services().rfdc.apply(board_id, request)
        services().management.add_audit("rfdc.applied", f"{user.username} applied RFDC runtime configuration", user.id, board_id, {"revision": result.revision})
        return result
    except Exception as exc:
        raise http_error(exc) from exc


@app.get("/api/tests", response_model=list[PerformanceTestRecord])
def list_performance_tests(_user: UserRecord = Depends(require_user)) -> list[PerformanceTestRecord]:
    return services().performance.store.list()


@app.post("/api/tests", response_model=PerformanceTestRecord, status_code=201)
def create_performance_test(
    request: PerformanceTestCreateRequest,
    user: UserRecord = Depends(require_mutation_user),
) -> PerformanceTestRecord:
    try:
        if not request.dry_run:
            services().management.require_lease(user, request.board_id)
        result = services().performance.create(request)
        services().management.add_audit("test.created", f"{user.username} created {request.kind.value} performance test", user.id, request.board_id)
        return result
    except Exception as exc:
        raise http_error(exc) from exc


def performance_test(test_id: str) -> PerformanceTestRecord:
    return services().performance.store.get(test_id)


def check_test_control(test: PerformanceTestRecord, user: UserRecord) -> None:
    if not test.dry_run:
        services().management.require_lease(user, test.board_id)


@app.get("/api/tests/{test_id}", response_model=PerformanceTestRecord)
def get_performance_test(test_id: str, _user: UserRecord = Depends(require_user)) -> PerformanceTestRecord:
    try:
        return performance_test(test_id)
    except Exception as exc:
        raise http_error(exc) from exc


@app.get("/api/tests/{test_id}/points", response_model=list[PerformancePointRecord])
def performance_points(test_id: str, _user: UserRecord = Depends(require_user)) -> list[PerformancePointRecord]:
    try:
        performance_test(test_id)
        return services().performance.store.points(test_id)
    except Exception as exc:
        raise http_error(exc) from exc


@app.post("/api/tests/{test_id}/start", response_model=PerformanceTestRecord)
def start_performance_test(test_id: str, user: UserRecord = Depends(require_mutation_user)) -> PerformanceTestRecord:
    try:
        test = performance_test(test_id)
        check_test_control(test, user)
        result = services().performance.start(test_id)
        services().events.publish({"type": "test.started", "data": result.model_dump(mode="json")})
        return result
    except Exception as exc:
        raise http_error(exc) from exc


@app.post("/api/tests/{test_id}/pause", response_model=PerformanceTestRecord)
def pause_performance_test(test_id: str, user: UserRecord = Depends(require_mutation_user)) -> PerformanceTestRecord:
    try:
        test = performance_test(test_id)
        check_test_control(test, user)
        return services().performance.pause(test_id)
    except Exception as exc:
        raise http_error(exc) from exc


@app.post("/api/tests/{test_id}/abort", response_model=PerformanceTestRecord)
def abort_performance_test(test_id: str, user: UserRecord = Depends(require_mutation_user)) -> PerformanceTestRecord:
    try:
        test = performance_test(test_id)
        check_test_control(test, user)
        return services().performance.abort(test_id)
    except Exception as exc:
        raise http_error(exc) from exc


@app.post("/api/tests/{test_id}/points/{point_id}/execute", response_model=PerformancePointRecord)
def execute_performance_point(test_id: str, point_id: int, user: UserRecord = Depends(require_mutation_user)) -> PerformancePointRecord:
    try:
        test = performance_test(test_id)
        check_test_control(test, user)
        return services().performance.execute_point(test_id, point_id)
    except Exception as exc:
        raise http_error(exc) from exc


@app.post("/api/tests/{test_id}/points/{point_id}/measurement", response_model=PerformancePointRecord)
def record_performance_measurement(
    test_id: str,
    point_id: int,
    measurement: dict[str, object],
    user: UserRecord = Depends(require_mutation_user),
) -> PerformancePointRecord:
    try:
        test = performance_test(test_id)
        check_test_control(test, user)
        return services().performance.record_measurement(test_id, point_id, measurement)
    except Exception as exc:
        raise http_error(exc) from exc


@app.get("/api/tests/{test_id}/export.csv")
def export_performance_csv(test_id: str, _user: UserRecord = Depends(require_user)) -> StreamingResponse:
    try:
        content = services().performance.export_csv(test_id)
        return StreamingResponse(iter([content]), media_type="text/csv", headers={"Content-Disposition": f'attachment; filename="{test_id}.csv"'})
    except Exception as exc:
        raise http_error(exc) from exc


@app.get("/api/tests/{test_id}/export.json")
def export_performance_json(test_id: str, _user: UserRecord = Depends(require_user)) -> StreamingResponse:
    try:
        content = json.dumps(services().performance.export_json(test_id), ensure_ascii=False, indent=2)
        return StreamingResponse(iter([content]), media_type="application/json", headers={"Content-Disposition": f'attachment; filename="{test_id}.json"'})
    except Exception as exc:
        raise http_error(exc) from exc


def run_action(run_id: str, action: str, user: UserRecord) -> RunRecord:
    try:
        record = services().store.get(run_id)
        if record is None:
            raise KeyError(run_id)
        if not services().management.can_manage_run(run_id, user):
            raise PermissionError("only the run owner may control this run")
        if not record.dry_run:
            services().management.require_lease(user, record.board_ids[0])
        if action == "arm":
            return services().runs.arm(run_id)
        if action in {"start", "trigger"}:
            return services().runs.start(run_id, manual=True)
        if action == "abort":
            return services().runs.abort(run_id)
    except Exception as exc:
        raise http_error(exc) from exc
    raise HTTPException(404, f"unknown action {action}")


@app.post("/api/runs/{run_id}/arm", response_model=RunRecord)
def arm_run(run_id: str, user: UserRecord = Depends(require_mutation_user)) -> RunRecord:
    return run_action(run_id, "arm", user)


@app.post("/api/runs/{run_id}/start", response_model=RunRecord)
def start_run(run_id: str, user: UserRecord = Depends(require_mutation_user)) -> RunRecord:
    return run_action(run_id, "start", user)


@app.post("/api/runs/{run_id}/trigger", response_model=RunRecord)
def trigger_run(run_id: str, user: UserRecord = Depends(require_mutation_user)) -> RunRecord:
    return run_action(run_id, "trigger", user)


@app.post("/api/runs/{run_id}/abort", response_model=RunRecord)
def abort_run(run_id: str, user: UserRecord = Depends(require_mutation_user)) -> RunRecord:
    return run_action(run_id, "abort", user)


async def save_upload(upload: UploadFile, directory: Path, suffix: str) -> tuple[Path, str, int]:
    filename = Path(upload.filename or "").name
    if not filename.lower().endswith(suffix):
        raise HTTPException(422, f"expected {suffix} file")
    target = directory / filename
    digest = hashlib.sha256()
    size = 0
    try:
        with target.open("xb") as stream:
            while chunk := await upload.read(1024 * 1024):
                size += len(chunk)
                if size > ARTIFACT_MAX_BYTES:
                    raise HTTPException(413, "artifact exceeds configured upload limit")
                digest.update(chunk)
                stream.write(chunk)
    except Exception:
        target.unlink(missing_ok=True)
        raise
    return target, digest.hexdigest(), size


@app.get("/api/artifacts", response_model=list[ArtifactRecord])
def list_artifacts(_user: UserRecord = Depends(require_user)) -> list[ArtifactRecord]:
    return services().management.list_artifacts()


@app.post("/api/admin/artifacts", response_model=ArtifactRecord, status_code=201)
async def upload_artifact(
    label: str = Form(..., min_length=1, max_length=120),
    target_profile: str = Form(...),
    bitstream: UploadFile = File(...),
    firmware: UploadFile = File(...),
    actor: UserRecord = Depends(require_admin),
) -> ArtifactRecord:
    if target_profile not in TARGET_PROFILES:
        raise HTTPException(422, "unsupported target profile")
    directory = services().root / "artifacts" / uuid.uuid4().hex
    directory.mkdir(parents=True, exist_ok=False)
    try:
        bit_path, bit_hash, bit_size = await save_upload(bitstream, directory, ".bit")
        elf_path, elf_hash, elf_size = await save_upload(firmware, directory, ".elf")
        artifact = services().management.add_artifact(
            label=label, target_profile=target_profile, bit_name=bit_path.name, elf_name=elf_path.name,
            bit_path=bit_path, elf_path=elf_path, bit_sha256=bit_hash, elf_sha256=elf_hash,
            bit_size=bit_size, elf_size=elf_size, user=actor,
        )
        services().management.add_audit("artifact.uploaded", f"{actor.username} uploaded {label}", actor.id, metadata={"artifact_id": artifact.id})
        return artifact
    except Exception:
        shutil.rmtree(directory, ignore_errors=True)
        raise


@app.post("/api/admin/boards/{board_id}/programs", response_model=ProgramJob, status_code=202)
def create_program(board_id: str, request: ProgramCreateRequest, actor: UserRecord = Depends(require_admin)) -> ProgramJob:
    try:
        job = services().programmer.create(board_id, request.artifact_id, actor)
        services().management.add_audit("program.queued", f"{actor.username} queued JTAG deployment", actor.id, board_id, {"job_id": job.id})
        return job
    except Exception as exc:
        raise http_error(exc) from exc


@app.get("/api/programs", response_model=list[ProgramJob])
def list_programs(_user: UserRecord = Depends(require_user)) -> list[ProgramJob]:
    return services().management.list_program_jobs()


@app.get("/api/programs/{job_id}/logs", response_model=list[SerialLogLine])
def program_logs(job_id: str, _user: UserRecord = Depends(require_user)) -> list[SerialLogLine]:
    try:
        services().management.program_job(job_id)
        return services().management.program_logs(job_id)
    except Exception as exc:
        raise http_error(exc) from exc


@app.get("/api/audit", response_model=list[AuditEvent])
def audit_events(_user: UserRecord = Depends(require_admin_read)) -> list[AuditEvent]:
    return services().management.audit_events()


@app.websocket("/api/events")
async def event_socket(websocket: WebSocket) -> None:
    user, _csrf = services().management.session_user(websocket.cookies.get(SESSION_COOKIE))
    if user is None:
        await websocket.close(code=4401)
        return
    await websocket.accept()
    queue = services().events.subscribe()
    try:
        await websocket.send_json({"type": "service.ready", "data": {"username": user.username}})
        while True:
            event_task = asyncio.create_task(queue.get())
            client_task = asyncio.create_task(websocket.receive())
            done, pending = await asyncio.wait({event_task, client_task}, return_when=asyncio.FIRST_COMPLETED)
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
            if client_task in done:
                message = client_task.result()
                if message["type"] == "websocket.disconnect":
                    break
                continue
            await websocket.send_json(event_task.result())
    except (WebSocketDisconnect, asyncio.CancelledError):
        pass
    finally:
        services().events.unsubscribe(queue)


if STATIC_DIR.exists():
    app.mount("/assets", StaticFiles(directory=STATIC_DIR / "assets"), name="assets")

    @app.get("/")
    def index() -> FileResponse:
        return FileResponse(STATIC_DIR / "index.html")
