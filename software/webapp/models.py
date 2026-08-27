from __future__ import annotations

from enum import Enum
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator


class BoardState(str, Enum):
    OFFLINE = "OFFLINE"
    IDLE = "IDLE"
    READY = "READY"
    ARMED = "ARMED"
    RUNNING = "RUNNING"
    DONE = "DONE"
    FAULT = "FAULT"
    MUTED = "MUTED"


class RunState(str, Enum):
    QUEUED = "QUEUED"
    GENERATING = "GENERATING"
    UPLOADING = "UPLOADING"
    READY = "READY"
    ARMED = "ARMED"
    RUNNING = "RUNNING"
    DONE = "DONE"
    FAULT = "FAULT"
    ABORTED = "ABORTED"


class BoardProfile(BaseModel):
    id: str
    name: str
    ip: str
    port: int = Field(1234, ge=1, le=65535)
    mac: str
    bootstrap_ip: str = "192.168.254.254"
    desired_ip: str = ""
    active_ip: str = ""
    desired_mac: str = ""
    active_mac: str = ""
    device_uid: str = ""
    network_revision: int = Field(0, ge=0)
    network_apply_status: Literal["unknown", "pending", "applied", "failed"] = "unknown"
    network_apply_error: str = ""
    udp_interface: str = "enp225s0f0"
    udp_source_ip: str = "192.168.1.10"
    clock_source: Literal["onboard"]
    enabled: bool = True
    model: str = "XCZU47DR RFDC"
    target_profile: str = "custom_xczu47dr"
    jtag_cable_serial: str = ""
    serial_path: str = ""
    baud_rate: int = Field(115200, ge=300, le=4_000_000)
    serial_status: str = "missing"
    serial_error: str = ""
    location: str = ""
    notes: str = ""
    last_seen_at: str = ""
    lease: "LeaseRecord | None" = None


class NetworkInterfaceInfo(BaseModel):
    name: str
    present: bool
    operstate: str
    carrier: bool
    ipv4_addresses: list[str] = Field(default_factory=list)
    message: str = ""


class BoardScanResult(BaseModel):
    interface: str
    target: str
    ok: bool
    stage: Literal["host_nic", "discovery", "network_apply", "rfctrl2"] = "discovery"
    board_id: str = ""
    device_uid: str = ""
    build_profile: str = ""
    active_ip: str = ""
    active_mac: str = ""
    message: str = ""


class BoardScanResponse(BaseModel):
    boards: list[BoardProfile] = Field(default_factory=list)
    interfaces: list[NetworkInterfaceInfo] = Field(default_factory=list)
    results: list[BoardScanResult] = Field(default_factory=list)


class CapabilityReport(BaseModel):
    source: str
    effective: list[str] = Field(default_factory=list)
    permitted: list[str] = Field(default_factory=list)
    ambient: list[str] = Field(default_factory=list)
    required: list[str] = Field(default_factory=list)
    missing: list[str] = Field(default_factory=list)
    ok: bool = False


class BoardStatus(BaseModel):
    board_id: str
    state: BoardState
    online: bool
    protocol_version: int = 0
    hardware_profile: str = "xczu47dr-rfdc-6g4-16x"
    sample_rate_hz: float = 400e6
    interpolation: int = 16
    axis_hz: float = 50e6
    hmc_locked: bool | None = None
    rfdc_ready: bool | None = None
    rfdc_capabilities: int = 0
    rfdc_config_valid_mask: int = 0
    rfdc_config_busy: bool = False
    dac_mts_required: bool = False
    dac_mts_ready: bool = False
    dac_mts_failed: bool = False
    dac_mts_tile_mask: int = 0
    dac_mts_error: int = 0
    nco_sync_ready: bool = False
    nco_sync_epoch: int = 0
    playback_armed: bool = False
    playback_prepared: bool = False
    playback_running: bool = False
    play_config_channel_mask: int = 0
    play_fifo_valid_mask: int = 0
    play_fifo_ready_mask: int = 0
    play_executor_state: int = 0
    play_ddr_read_counter: int = 0
    play_bad_instr_count: int = 0
    play_prefill_ready: bool = False
    play_active_valid: bool = False
    play_pending_valid: bool = False
    rfdc_last_revision: int = 0
    rfdc_last_error: int = 0
    rfdc_last_error_stage: int = 0
    rfdc_last_error_address: int = 0
    underflow_mask: int = 0
    error_count: int = 0
    sync_epoch: int = 0
    hardware_tick: int = 0
    physical_link: bool | None = None
    udp_interface: str = ""
    udp_source_ip: str = ""
    active_ip: str = ""
    bootstrap_reachable: bool = False
    network_configured: bool = False
    device_uid: str = ""
    network_revision: int = 0
    network_apply_status: str = "unknown"
    network_apply_error: str = ""
    message: str = ""


class RfdcChannelConfig(BaseModel):
    channel: int = Field(ge=1, le=8)
    dac_output_current_ma: float = Field(20.0, ge=2.25, le=40.5)
    target_rf_hz: float = Field(0.0, ge=0.0, le=6.4e9)
    nco_hz: float = Field(0.0, ge=-3.2e9, le=3.2e9)
    nyquist_zone: Literal[1, 2] = 1
    data_offset_hz: float = Field(0.0, ge=-160e6, le=160e6)
    data_amplitude: float = Field(0.5, ge=-1.0, le=1.0)
    data_phase_deg: float = Field(0.0, ge=-3600.0, le=3600.0)
    nco_phase_deg: float = Field(0.0, ge=-3600.0, le=3600.0)
    # The user-requested NCO phase remains separate from the server-side
    # calibration applied at RFDC programming time.
    calibration_phase_deg: float = Field(0.0, ge=-3600.0, le=3600.0)
    actual_nco_hz: float | None = None
    actual_nyquist_zone: int | None = Field(default=None, ge=1, le=2)
    actual_nco_phase_deg: float | None = None
    actual_dac_output_current_ma: float | None = None
    nco_word: int | None = None
    phase_word: int | None = None
    vop_code: int | None = None
    hardware_status: int = 0

class BoardRfdcConfig(BaseModel):
    board_id: str
    channels: list[RfdcChannelConfig] = Field(min_length=8, max_length=8)
    revision: int = 0
    applied_at: str | None = None
    apply_status: Literal["unknown", "pending", "applied", "partial", "failed"] = "unknown"
    apply_error: str = ""
    requested_mask: int = Field(0xFF, ge=1, le=0xFF)
    applied_mask: int = Field(0, ge=0, le=0xFF)
    error_mask: int = Field(0, ge=0, le=0xFF)
    config_valid_mask: int = Field(0, ge=0, le=0xFF)
    failure_stage: int = 0
    failure_address: int = 0
    axi_response: int = 0

    @model_validator(mode="after")
    def validate_channels(self) -> "BoardRfdcConfig":
        if sorted(channel.channel for channel in self.channels) != list(range(1, 9)):
            raise ValueError("RFDC config requires exactly one configuration for CH1..CH8")
        return self


class PhaseCalibrationRequest(BaseModel):
    frequency_hz: int = Field(ge=0, le=6_400_000_000)
    channel: int = Field(ge=1, le=8)
    phase_deg: float = Field(ge=-3600.0, le=3600.0)


class PhaseCalibrationRecord(BaseModel):
    board_id: str
    device_uid: str
    frequency_hz: int
    channel: int
    phase_deg: float
    updated_at: str
    updated_by: str | None = None


class RfdcConfigApplyRequest(BaseModel):
    channels: list[RfdcChannelConfig] = Field(min_length=8, max_length=8)
    channel_mask: int = Field(0xFF, ge=1, le=0xFF)

    @model_validator(mode="after")
    def validate_channels(self) -> "RfdcConfigApplyRequest":
        if sorted(channel.channel for channel in self.channels) != list(range(1, 9)):
            raise ValueError("RFDC config requires exactly one configuration for CH1..CH8")
        for channel in self.channels:
            if channel.channel in (5, 6) and not 6.4 <= channel.dac_output_current_ma <= 32.0:
                raise ValueError(
                    f"CH{channel.channel} is DC-coupled; DAC current must be 6.4-32.0 mA"
                )
        return self


class PreflightCheck(BaseModel):
    key: str
    label: str
    state: Literal["pass", "warning", "fail", "info"]
    message: str


class BoardPreflight(BaseModel):
    board_id: str
    can_start_live: bool
    checks: list[PreflightCheck]
    checked_at: str


class UserRole(str, Enum):
    ADMIN = "admin"
    USER = "user"


class UserRecord(BaseModel):
    id: int
    username: str
    role: UserRole
    enabled: bool = True
    created_at: str


class SessionResponse(BaseModel):
    user: UserRecord | None
    csrf_token: str | None = None


class UserCreateRequest(BaseModel):
    username: str = Field(min_length=2, max_length=32, pattern=r"^[A-Za-z0-9_.-]+$")
    password: str = Field(min_length=8, max_length=256)
    role: UserRole = UserRole.USER
    enabled: bool = True


class UserUpdateRequest(BaseModel):
    password: str | None = Field(default=None, min_length=8, max_length=256)
    role: UserRole = UserRole.USER
    enabled: bool = True


class LoginRequest(BaseModel):
    username: str = Field(min_length=1, max_length=32)
    password: str = Field(min_length=1, max_length=256)


class LeaseRecord(BaseModel):
    id: int
    board_id: str
    user_id: int
    username: str
    status: Literal["active", "released", "forced"]
    starts_at: str
    released_at: str | None = None


class DiscoveryResource(BaseModel):
    id: int
    kind: Literal["jtag", "serial"]
    fingerprint: str
    label: str
    details: dict[str, object] = Field(default_factory=dict)
    state: Literal["pending", "registered"] = "pending"
    board_id: str | None = None
    first_seen_at: str
    last_seen_at: str


class SerialPortInfo(BaseModel):
    path: str
    stable_path: str = ""
    manufacturer: str = ""
    serial_number: str = ""
    vendor_id: str = ""
    product_id: str = ""
    bound_board_id: str | None = None


class SerialLogLine(BaseModel):
    line: str
    created_at: str


class SerialBindingRequest(BaseModel):
    path: str = Field(min_length=1, max_length=512)
    baud_rate: int = Field(115200, ge=300, le=4_000_000)


class ArtifactRecord(BaseModel):
    id: str
    label: str
    target_profile: str
    bit_name: str
    elf_name: str
    bit_sha256: str
    elf_sha256: str
    bit_size: int
    elf_size: int
    created_at: str
    created_by: str


class ProgramCreateRequest(BaseModel):
    artifact_id: str


class ProgramJob(BaseModel):
    id: str
    board_id: str
    artifact_id: str
    state: Literal["QUEUED", "PREFLIGHT", "RUNNING", "SUCCEEDED", "FAILED"]
    progress: float = Field(0.0, ge=0.0, le=1.0)
    created_at: str
    updated_at: str
    created_by: str
    error: str = ""


class AuditEvent(BaseModel):
    id: int
    type: str
    message: str
    username: str | None = None
    board_id: str | None = None
    created_at: str
    metadata: dict[str, object] = Field(default_factory=dict)


class BoardUpdateRequest(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    model: str = Field(default="XCZU47DR RFDC", max_length=120)
    ip: str = Field(min_length=1, max_length=64)
    port: int = Field(1234, ge=1, le=65535)
    mac: str = Field(default="", max_length=32)
    bootstrap_ip: str = Field(default="192.168.254.254", max_length=64)
    desired_ip: str = Field(default="", max_length=64)
    active_ip: str = Field(default="", max_length=64)
    desired_mac: str = Field(default="", max_length=32)
    active_mac: str = Field(default="", max_length=32)
    device_uid: str = Field(default="", max_length=64)
    network_revision: int = Field(default=0, ge=0)
    network_apply_status: Literal["unknown", "pending", "applied", "failed"] = "unknown"
    network_apply_error: str = Field(default="", max_length=512)
    udp_interface: str = Field(default="enp225s0f0", min_length=1, max_length=64)
    udp_source_ip: str = Field(default="192.168.1.10", max_length=64)
    clock_source: Literal["onboard"] = "onboard"
    target_profile: str = Field(default="custom_xczu47dr", max_length=64)
    jtag_cable_serial: str = Field(default="", max_length=128)
    serial_path: str = Field(default="", max_length=512)
    baud_rate: int = Field(115200, ge=300, le=4_000_000)
    location: str = Field(default="", max_length=120)
    notes: str = Field(default="", max_length=2000)
    enabled: bool = True

    @model_validator(mode="after")
    def normalize_network_fields(self) -> "BoardUpdateRequest":
        if not self.desired_ip:
            self.desired_ip = self.ip
        if not self.active_ip:
            self.active_ip = self.ip
        if not self.desired_mac:
            self.desired_mac = self.mac
        if not self.active_mac:
            self.active_mac = self.mac
        self.ip = self.active_ip
        self.mac = self.active_mac
        return self


class NetworkConfigRequest(BaseModel):
    revision: int = Field(ge=0)
    ip: str = Field(min_length=7, max_length=64)
    mac: str = Field(min_length=12, max_length=32)
    subnet_mask: str = Field(default="255.255.255.0", min_length=7, max_length=64)
    gateway: str = Field(default="0.0.0.0", min_length=7, max_length=64)
    port: int = Field(1234, ge=1, le=65535)


class NetworkConfigSnapshot(BaseModel):
    board_id: str
    device_uid: str = ""
    bootstrap_ip: str = "192.168.254.254"
    current_ip: str = ""
    desired_ip: str = ""
    current_mac: str = ""
    desired_mac: str = ""
    subnet_mask: str = "255.255.255.0"
    gateway: str = "0.0.0.0"
    port: int = Field(1234, ge=1, le=65535)
    udp_interface: str
    udp_source_ip: str
    revision: int = 0
    apply_status: Literal["unknown", "pending", "applied", "failed"] = "unknown"
    apply_error: str = ""
    physical_link: bool | None = None
    bootstrap_reachable: bool = False
    active_reachable: bool = False
    protocol_version: int = 0
    capabilities: int = 0
    link_state: int = 0


class ManualChannel(BaseModel):
    channel: int = Field(ge=1, le=8)
    enabled: bool = True
    waveform: str = "sine"
    format: Literal["iq", "real"] = "iq"
    frequency_mhz: float = Field(0.0, ge=-160.0, le=160.0)
    data_offset_mhz: float | None = Field(default=None, ge=-160.0, le=160.0)
    phase_deg: float = Field(0.0, ge=-3600.0, le=3600.0)
    amplitude: int | None = Field(default=None, ge=0, le=32767)
    data_amplitude: float | None = Field(default=None, ge=-1.0, le=1.0)
    duration_ns: float = Field(1000.0, gt=0.0, le=1e9)
    delay_ns: float = Field(0.0, ge=0.0, le=1e9)
    target_rf_mhz: float = Field(0.0, ge=0.0, le=6400.0)
    nco_mhz: float = Field(0.0, ge=-3200.0, le=3200.0)
    nyquist_zone: Literal[1, 2] = 1
    nco_phase_deg: float = Field(0.0, ge=-3600.0, le=3600.0)

    @field_validator("waveform")
    @classmethod
    def normalize_waveform(cls, value: str) -> str:
        waveform = str(value).lower()
        mapping = {
            "iq-sine": "sine",
            "sine": "sine",
            "iq-gaussian-sine": "xy",
            "pypulse": "xy",
            "burst": "xy",
            "quantum": "xy",
            "dc-iq-cw": "sine",
            "xy": "xy",
            "readout": "readout",
            "z": "z",
        }
        if waveform not in mapping:
            raise ValueError(f"waveform must be one of sine, xy, readout, z; got {value!r}")
        return mapping[waveform]

    @model_validator(mode="after")
    def resolve_data_offset(self) -> "ManualChannel":
        if self.data_offset_mhz is None:
            self.data_offset_mhz = self.frequency_mhz
        return self


class EzqChannel(BaseModel):
    channel: int = Field(ge=1, le=8)
    enabled: bool = True
    role: Literal["xy", "z", "readout"]
    start_ns: float = Field(0.0, ge=0.0, le=1e9)
    target_rf_mhz: float = Field(0.0, ge=0.0, le=6400.0)
    detune_mhz: float = Field(0.0, ge=-160.0, le=160.0)
    phase_deg: float = Field(0.0, ge=-3600.0, le=3600.0)
    amplitude: float = Field(0.25, ge=-1.0, le=1.0)
    duration_ns: float = Field(120.0, gt=0.0, le=1e9)
    xy_gate: Literal["x_pi", "y_pi", "x_half", "y_half", "x12_pi", "x12_half", "spec"] = "x_pi"
    z_shape: Literal["square", "diabatic_cz"] = "square"

    @model_validator(mode="after")
    def validate_fixed_role(self) -> "EzqChannel":
        expected = "xy" if self.channel <= 4 else "z" if self.channel <= 6 else "readout"
        if self.role != expected:
            raise ValueError(f"CH{self.channel} role is fixed to {expected}")
        return self


class BoardOverride(BaseModel):
    board_id: str
    channel_enabled: dict[int, bool] = Field(default_factory=dict)
    nco_offset_hz: dict[int, float] = Field(default_factory=dict)
    phase_offset_deg: dict[int, float] = Field(default_factory=dict)
    start_offset_ns: dict[int, float] = Field(default_factory=dict)

    @field_validator("channel_enabled", "nco_offset_hz", "phase_offset_deg", "start_offset_ns")
    @classmethod
    def validate_channels(cls, value: dict[int, object]) -> dict[int, object]:
        invalid = [channel for channel in value if not 1 <= int(channel) <= 8]
        if invalid:
            raise ValueError(f"channel override keys must be in 1..8, got {invalid}")
        return value


class WaveformRequest(BaseModel):
    name: str = Field("Untitled waveform", min_length=1, max_length=120)
    mode: Literal["manual", "ezq"] = "manual"
    loop: bool = False
    record_duration_ns: float = Field(10_000.0, gt=0.0, le=1e9)
    manual_channels: list[ManualChannel] = Field(default_factory=list)
    ezq_channels: list[EzqChannel] = Field(default_factory=list)

    @model_validator(mode="after")
    def validate_channels(self) -> "WaveformRequest":
        channels = self.manual_channels if self.mode == "manual" else self.ezq_channels
        if sorted(channel.channel for channel in channels) != list(range(1, 9)):
            raise ValueError(f"{self.mode} mode requires exactly one configuration for CH1..CH8")
        return self


class BoardWaveformJob(BaseModel):
    board_id: str = Field(min_length=1, max_length=120)
    waveform: WaveformRequest
    override: BoardOverride | None = None
    rfdc_config: BoardRfdcConfig | None = None


class PreviewRequest(BaseModel):
    waveform: WaveformRequest
    override: BoardOverride | None = None
    rfdc_config: BoardRfdcConfig | None = None
    fft_channel: int = Field(1, ge=1, le=8)


class PreviewSeries(BaseModel):
    channel: int
    role: str
    domain: Literal["iq", "real"]
    time_ns: list[float]
    value: list[float]
    i: list[int]
    q: list[int]
    active_start_ns: float | None
    active_end_ns: float | None


class PreviewResponse(BaseModel):
    sample_rate_hz: float
    record_duration_ns: float
    bytes_per_channel: int
    series: list[PreviewSeries]
    fft_channel: int
    fft_frequency_mhz: list[float]
    fft_db: list[float]
    warnings: list[str] = Field(default_factory=list)


class RunCreateRequest(BaseModel):
    jobs: list[BoardWaveformJob] = Field(min_length=1)
    dry_run: bool = False
    execution_mode: Literal["single", "synchronized"] = "single"
    completion_mode: Literal["upload", "one_shot"] = "upload"
    playback_mode: Literal["single", "continuous_sine"] = "single"
    one_shot_duration_ms: float = Field(0.0, ge=0.0, le=3_600_000.0)

    @model_validator(mode="after")
    def validate_v1_single_board(self) -> "RunCreateRequest":
        board_ids = [job.board_id for job in self.jobs]
        if len(board_ids) != len(set(board_ids)):
            raise ValueError("each board may appear only once in a run")
        if self.execution_mode == "single":
            if len(self.jobs) != 1:
                raise ValueError("single-board runs require exactly one board")
        elif self.execution_mode == "synchronized":
            if len(self.jobs) != 2:
                raise ValueError("synchronized runs require exactly two boards")
        else:
            raise ValueError(f"unsupported execution_mode {self.execution_mode}")
        if self.playback_mode == "continuous_sine":
            waveform = self.jobs[0].waveform
            if not waveform.loop:
                raise ValueError("continuous playback requires waveform.loop=true")
            if waveform.mode != "manual":
                raise ValueError("continuous playback currently supports manual waveforms only")
            enabled = [channel for channel in waveform.manual_channels if channel.enabled]
            if not enabled:
                raise ValueError("continuous playback requires at least one enabled channel")
        return self

    @property
    def board_ids(self) -> list[str]:
        return [job.board_id for job in self.jobs]


class SyncBoardResult(BaseModel):
    board_id: str
    hmc_done: bool
    sync_done: bool
    dac_mts_ready: bool
    nco_sync_ready: bool
    dac_mts_tile_mask: int = 0
    message: str = ""


class SyncRequest(BaseModel):
    master_board_id: str
    slave_board_id: str


class SyncResult(BaseModel):
    epoch: int
    boards: list[SyncBoardResult]
    ok: bool
    message: str = ""


class MaxLengthTestState(str, Enum):
    PENDING = "PENDING"
    UPLOADING = "UPLOADING"
    PLAYING = "PLAYING"
    COMPLETED = "COMPLETED"
    FAILED = "FAILED"
    ABORTED = "ABORTED"


class MaxLengthTestCreateRequest(BaseModel):
    name: str = Field("通道极限长度测试", min_length=1, max_length=120)
    board_id: str = Field(min_length=1, max_length=120)
    bytes_per_channel: int = Field(0, ge=0)
    pattern: Literal["lowfreq-sine", "cw-marker"] = "lowfreq-sine"
    sine_freq_hz: float = Field(10.0, ge=0.0, le=1_000_000.0)
    sine_amplitude: int = Field(4096, ge=0, le=32767)
    beats_per_datagram: int = Field(0, ge=0)
    auto_trigger: bool = True
    dry_run: bool = False


class MaxLengthTestRecord(BaseModel):
    id: str
    name: str
    board_id: str
    state: MaxLengthTestState
    progress: float = Field(0.0, ge=0.0, le=1.0)
    bytes_per_channel: int = 0
    physical_bytes: int = 0
    datagrams: int = 0
    pattern: str = "lowfreq-sine"
    sine_freq_hz: float = 10.0
    sine_amplitude: int = 4096
    beats_per_datagram: int = 0
    auto_trigger: bool = True
    dry_run: bool = False
    upload_elapsed_s: float = 0.0
    upload_mbps: float = 0.0
    theoretical_duration_s: float = 0.0
    play_elapsed_s: float = 0.0
    read_counter: int = 0
    bad_instr_count: int = 0
    underflow_mask: int = 0
    error: str = ""
    created_at: str
    updated_at: str


class RunRecord(BaseModel):
    id: str
    name: str
    state: RunState
    dry_run: bool
    board_ids: list[str]
    start_mode: str = "trigger"
    execution_mode: str = "single"
    created_at: str
    updated_at: str
    artifact_dir: str
    progress: float = Field(0.0, ge=0.0, le=1.0)
    error: str = ""
    completion_mode: str = "upload"
    playback_mode: str = "single"
    loaded: bool = False


class TestKind(str, Enum):
    AMPLITUDE = "amplitude"
    FREQUENCY = "frequency"
    PHASE = "phase"


class TestSessionState(str, Enum):
    DRAFT = "DRAFT"
    RUNNING = "RUNNING"
    PAUSED = "PAUSED"
    COMPLETED = "COMPLETED"
    ABORTED = "ABORTED"
    FAILED = "FAILED"


class PerformanceTestCreateRequest(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    board_id: str = Field(min_length=1, max_length=120)
    kind: TestKind
    channel: int = Field(1, ge=1, le=8)
    channels: list[int] = Field(default_factory=list)
    mode: Literal["automatic", "manual"] = "automatic"
    points: list[dict[str, object]] = Field(min_length=1)
    settle_ms: float = Field(100.0, ge=0.0, le=60_000.0)
    auto_mute: bool = True
    dry_run: bool = False
    scan_axis: str = Field("custom", max_length=48)
    scan_start: float | None = None
    scan_stop: float | None = None
    scan_step: float | None = None
    scan_unit: str = Field("", max_length=16)

    @field_validator("channels")
    @classmethod
    def validate_test_channels(cls, value: list[int]) -> list[int]:
        if any(channel < 1 or channel > 8 for channel in value):
            raise ValueError("test channels must be in 1..8")
        if len(set(value)) != len(value):
            raise ValueError("test channels must be unique")
        return value


class PerformanceTestRecord(BaseModel):
    id: str
    name: str
    board_id: str
    kind: TestKind
    channel: int
    channels: list[int]
    mode: Literal["automatic", "manual"]
    state: TestSessionState
    current_point: int = 0
    total_points: int = 0
    settle_ms: float = 100.0
    auto_mute: bool = True
    dry_run: bool = False
    scan_axis: str = "custom"
    scan_start: float | None = None
    scan_stop: float | None = None
    scan_step: float | None = None
    scan_unit: str = ""
    created_at: str
    updated_at: str
    error: str = ""
    environment: dict[str, object] = Field(default_factory=dict)


class PerformancePointRecord(BaseModel):
    id: str
    test_id: str
    index: int
    state: Literal["PENDING", "RUNNING", "READY", "MEASURED", "FAILED", "SKIPPED"]
    parameters: dict[str, object] = Field(default_factory=dict)
    measurement: dict[str, object] = Field(default_factory=dict)
    error: str = ""
    updated_at: str


class RunEvent(BaseModel):
    run_id: str
    timestamp: str
    level: Literal["info", "warning", "error"] = "info"
    message: str


class ActionResponse(BaseModel):
    ok: bool
    message: str


BoardProfile.model_rebuild()
