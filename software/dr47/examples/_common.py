"""250 MHz 板级示例共用辅助函数。

本模块只服务于 ``software/dr47/examples`` 下的真实硬件示例，不是驱动公开
API。网络入网、波形生成和状态轮询集中在这里，避免各个正式入口逐渐产生
不一致的行为。
"""

from __future__ import annotations

import math
import os
import time
from collections.abc import Sequence
from typing import Callable

import numpy as np

from ..capabilities import PlaybackState
from ..device import Dr47Device
from ..errors import DriverError
from ..hardware_test_network import (
    BoardNetworkAssignment,
    EnrolledBoard,
    discover_and_provision_boards,
)
from ..waveforms import (
    iq_duration_to_interleaved_sample_count,
    make_iq_gaussian_sine_interleaved,
    place_interleaved_iq_in_record,
)
from ..protocol import DDR_MAX_BYTES_PER_CHANNEL


BOARD_PORT = 1234
UDP_INTERFACE = os.environ.get("RFSOC_UDP_INTERFACE", "enp1s0f0")
DISCOVERY_SOURCE_IP = os.environ.get("RFSOC_DISCOVERY_SOURCE_IP", "169.254.250.11")
DISCOVERY_SOURCE_CIDR = os.environ.get(
    "RFSOC_DISCOVERY_SOURCE_CIDR", "169.254.250.11/16"
)
DISCOVERY_BROADCAST_IP = os.environ.get(
    "RFSOC_DISCOVERY_BROADCAST_IP", "169.254.255.255"
)
CONTROL_SOURCE_IP = os.environ.get("RFSOC_CONTROL_SOURCE_IP", DISCOVERY_SOURCE_IP)

# 250 MHz 分支的默认板卡地址。正式使用前只需修改 UID/IP/MAC 常量，不需要
# 给示例增加命令行参数。
TARGET_SUBNET_MASK = "255.255.0.0"
TARGET_GATEWAY = "0.0.0.0"
MASTER_TARGET_IP = "169.254.100.101"
SLAVE_TARGET_IP = "169.254.100.102"
MASTER_DEVICE_UID = ""
SLAVE_DEVICE_UID = ""
MASTER_MATCH_MAC = ""
SLAVE_MATCH_MAC = ""
MASTER_TARGET_MAC: str | None = None
SLAVE_TARGET_MAC: str | None = None

SAMPLE_RATE_HZ = 400_000_000.0
RF_NCO_GHZ = 1.0
BASEBAND_GHZ = 0.0
PULSE_DURATION_NS = 60.0
PULSE_DELAY_NS = 100.0
RECORD_DURATION_NS = 10_000.0
AMPLITUDE = 1.0
GAIN = 1.0
CHANNEL_MASK = 0x01
POLL_INTERVAL_S = 0.02


def enroll(assignments: list[BoardNetworkAssignment]) -> dict[str, EnrolledBoard]:
    """广播发现、按角色/UID选择、分配 IP 并回读验证。"""

    enrolled = discover_and_provision_boards(
        assignments,
        interface=UDP_INTERFACE,
        discovery_source_ip=DISCOVERY_SOURCE_IP,
        discovery_source_cidr=DISCOVERY_SOURCE_CIDR,
        control_source_ip=CONTROL_SOURCE_IP,
        broadcast_ip=DISCOVERY_BROADCAST_IP,
        port=BOARD_PORT,
    )
    return {item.sync_role: item for item in enrolled}


def new_device(board: EnrolledBoard) -> Dr47Device:
    """创建绑定到已验证正式 IP 的驱动对象并连接板卡。"""

    device = Dr47Device(
        ip=board.ip,
        port=board.port or BOARD_PORT,
        udp_interface=UDP_INTERFACE,
        udp_source_ip=CONTROL_SOURCE_IP,
        timeout_s=1.0,
        retries=2,
        batch_mode=True,
    )
    print(f"连接{board.label}：{board.ip}:{board.port}，UID={board.device_uid}")
    device.connect()
    return device


def show_status(device: Dr47Device, label: str):
    """读取并打印一次完整的同步、对齐、Trigger 和播放状态。"""

    status = device.status(refresh=True)
    caps = status.capabilities
    print(
        f"{label}: state={status.state.value}, role={caps.sync_role}, "
        f"mode={caps.sync_mode}, sync_seen={caps.sync_seen}, "
        f"sync_ready={caps.sync_link_ready}, align_busy={caps.sync_align_busy}, "
        f"align_epoch={caps.sync_alignment_epoch}, "
        f"trigger(in/accepted/out)={caps.trigger_input_count}/"
        f"{caps.trigger_accepted_count}/{caps.trigger_output_count}"
    )
    return status


def ensure_idle(device: Dr47Device, label: str) -> None:
    """停止上一次测试残留的播放，保证模式/波形配置从 IDLE 开始。"""

    status = device.status(refresh=True)
    if status.state is not PlaybackState.IDLE:
        print(f"{label} 不是 IDLE，先 ABORT_MUTE")
        device.abort_mute()
        wait_state(device, PlaybackState.IDLE, f"{label} 清理")


def wait_rfdc_ready(device: Dr47Device, label: str, timeout_s: float = 30.0) -> None:
    """等待启动阶段 RFDC、DAC MTS 与 NCO SYSREF 均就绪。"""

    deadline = time.monotonic() + timeout_s
    last = None
    while time.monotonic() < deadline:
        last = device.status(refresh=True)
        caps = last.capabilities
        if caps.rfdc_ready and caps.dac_mts_ready and caps.nco_sync_ready:
            return
        if caps.dac_mts_failed:
            raise AssertionError(
                f"{label} DAC MTS 失败：error=0x{caps.dac_mts_error:04X}"
            )
        time.sleep(POLL_INTERVAL_S)
    actual = "unknown" if last is None else last.capabilities
    raise AssertionError(f"{label} RFDC 未就绪：{actual}")


def wait_state(
    device: Dr47Device,
    expected: PlaybackState,
    label: str,
    timeout_s: float = 10.0,
) -> None:
    """等待板卡真实状态，而不是把命令 ACK 当作状态完成。"""

    deadline = time.monotonic() + timeout_s
    last = None
    while time.monotonic() < deadline:
        last = device.status(refresh=True)
        if last.state is expected:
            return
        time.sleep(POLL_INTERVAL_S)
    actual = "unknown" if last is None else last.state.value
    raise AssertionError(f"{label} timeout: expected={expected.value}, actual={actual}")


def wait_until(
    predicate: Callable[[], bool], label: str, timeout_s: float = 10.0
) -> None:
    """轮询任意硬件条件，统一超时错误格式。"""

    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(POLL_INTERVAL_S)
    raise AssertionError(f"{label} timeout")


def make_gaussian_record(
    *,
    rf_nco_frequency_ghz: float = RF_NCO_GHZ,
    baseband_frequency_ghz: float = BASEBAND_GHZ,
    duration_ns: float = PULSE_DURATION_NS,
    delay_ns: float = PULSE_DELAY_NS,
    record_duration_ns: float = RECORD_DURATION_NS,
    amplitude: float = AMPLITUDE,
    sample_rate_hz: float = SAMPLE_RATE_HZ,
    phase_rad: float = 0.0,
    fwhm_ns: float | None = None,
) -> np.ndarray:
    """生成带记录内延迟的有限高斯 IQ 波形。

    ``rf_nco_frequency_ghz`` 只用于让调用处的配置意图清晰；实际射频载波由
    ``configure_and_arm`` 通过 RFDC NCO 设置，上传记录是 400 MS/s 复基带。
    """

    del rf_nco_frequency_ghz
    sample_rate_hz = float(sample_rate_hz)
    duration_s = float(duration_ns) * 1e-9
    delay_s = float(delay_ns) * 1e-9
    if not 0.0 < float(amplitude) <= 1.0:
        raise ValueError("amplitude must be in (0, 1]")
    if abs(float(baseband_frequency_ghz) * 1e9) > sample_rate_hz / 2.0:
        raise ValueError("baseband frequency exceeds complex-sample Nyquist limit")
    if delay_s < 0.0 or float(record_duration_ns) * 1e-9 < delay_s + duration_s:
        raise ValueError("record duration must contain delay plus pulse duration")
    active_count = iq_duration_to_interleaved_sample_count(duration_s, sample_rate_hz)
    fwhm_s = duration_s / 2.0 if fwhm_ns is None else float(fwhm_ns) * 1e-9
    if fwhm_s <= 0.0:
        raise ValueError("fwhm_ns must be positive")
    active = make_iq_gaussian_sine_interleaved(
        frequency_hz=float(baseband_frequency_ghz) * 1e9,
        phase_rad=float(phase_rad),
        amplitude=round(float(amplitude) * 32767.0),
        sample_rate_hz=sample_rate_hz,
        duration_s=duration_s,
        sample_count=active_count,
        fwhm_s=fwhm_s,
        q_sign=-1,
        hls_xy_drag=False,
    )
    return place_interleaved_iq_in_record(
        active,
        delay_s=delay_s,
        record_duration_s=float(record_duration_ns) * 1e-9,
        sample_rate_hz=sample_rate_hz,
    )


def make_gaussian_burst_record(
    *,
    rf_nco_frequency_ghz: float = RF_NCO_GHZ,
    baseband_frequency_ghz: float = BASEBAND_GHZ,
    pulse_duration_ns: float = PULSE_DURATION_NS,
    first_delay_ns: float = PULSE_DELAY_NS,
    interval_ns: float = 1_000.0,
    pulse_count: int = 1,
    record_duration_ns: float | None = None,
    amplitude: float = AMPLITUDE,
    sample_rate_hz: float = SAMPLE_RATE_HZ,
    phase_rad: float = 0.0,
    fwhm_ns: float | None = None,
) -> np.ndarray:
    """Build one finite record containing ``pulse_count`` Gaussian pulses.

    ``first_delay_ns`` is the delay from the external Trigger to the first
    pulse. ``interval_ns`` is the start-to-start spacing of later pulses. The
    returned record is played once, so one accepted Trigger launches the whole
    burst without requiring another hardware or software Trigger.
    """

    sample_rate = float(sample_rate_hz)
    pulse_duration = float(pulse_duration_ns)
    first_delay = float(first_delay_ns)
    interval = float(interval_ns)
    count = int(pulse_count)
    if count <= 0:
        raise ValueError("pulse_count must be positive")
    if not math.isfinite(sample_rate) or sample_rate <= 0.0:
        raise ValueError("sample_rate_hz must be positive and finite")
    if not math.isfinite(pulse_duration) or pulse_duration <= 0.0:
        raise ValueError("pulse_duration_ns must be positive and finite")
    if not math.isfinite(first_delay) or first_delay < 0.0:
        raise ValueError("first_delay_ns must be non-negative and finite")
    if not math.isfinite(interval) or interval <= 0.0:
        raise ValueError("interval_ns must be positive and finite")
    fwhm_s = pulse_duration * 1e-9 / 2.0 if fwhm_ns is None else float(fwhm_ns) * 1e-9
    if not math.isfinite(fwhm_s) or fwhm_s <= 0.0:
        raise ValueError("fwhm_ns must be positive")
    if not 0.0 < float(amplitude) <= 1.0:
        raise ValueError("amplitude must be in (0, 1]")
    if abs(float(baseband_frequency_ghz) * 1e9) > sample_rate / 2.0:
        raise ValueError("baseband frequency exceeds complex-sample Nyquist limit")

    active_count = iq_duration_to_interleaved_sample_count(
        pulse_duration * 1e-9, sample_rate
    )
    active_complex_samples = active_count // 2
    first_complex_sample = int(round(first_delay * 1e-9 * sample_rate))
    interval_samples = int(round(interval * 1e-9 * sample_rate))
    if interval_samples < active_complex_samples:
        raise ValueError(
            "interval_ns must be at least the aligned pulse duration to avoid overlap"
        )
    required_complex_samples = (
        first_complex_sample
        + (count - 1) * interval_samples
        + active_complex_samples
    )
    required_duration_ns = required_complex_samples / sample_rate * 1e9
    if record_duration_ns is None:
        total_duration_ns = required_duration_ns
    else:
        total_duration_ns = float(record_duration_ns)
        if total_duration_ns < required_duration_ns:
            raise ValueError(
                f"record_duration_ns={total_duration_ns:g} is shorter than the "
                f"burst end at {required_duration_ns:g} ns"
            )

    record_count = iq_duration_to_interleaved_sample_count(
        total_duration_ns * 1e-9, sample_rate
    )
    record_bytes = record_count * np.dtype(np.int16).itemsize
    if record_bytes > DDR_MAX_BYTES_PER_CHANNEL:
        max_duration_ns = DDR_MAX_BYTES_PER_CHANNEL / (4.0 * sample_rate) * 1e9
        raise ValueError(
            f"burst record needs {record_bytes} bytes per channel, above the "
            f"DDR limit {DDR_MAX_BYTES_PER_CHANNEL}; maximum is about "
            f"{max_duration_ns:g} ns at this sample rate"
        )
    record = np.zeros(record_count, dtype=np.int16)

    active = make_iq_gaussian_sine_interleaved(
        frequency_hz=float(baseband_frequency_ghz) * 1e9,
        phase_rad=float(phase_rad),
        amplitude=round(float(amplitude) * 32767.0),
        sample_rate_hz=sample_rate,
        duration_s=pulse_duration * 1e-9,
        sample_count=active_count,
        fwhm_s=fwhm_s,
        q_sign=-1,
        hls_xy_drag=False,
    )
    for pulse_index in range(count):
        start = (first_complex_sample + pulse_index * interval_samples) * 2
        record[start:start + active_count] = active
    del rf_nco_frequency_ghz
    return record


def _make_upload_progress(
    label: str,
    *,
    width: int = 30,
    min_interval_s: float = 0.25,
) -> tuple[Callable[[int, int], None], Callable[[], None]]:
    """Create a throttled terminal progress callback and its cleanup hook.

    The driver invokes the callback once per waveform UDP packet.  Keeping the
    throttling here avoids terminal output becoming the bottleneck for a long
    upload while still reporting packet-based progress rather than elapsed
    time.  The cleanup hook makes sure an interrupted upload leaves the next
    log message on a fresh line.
    """

    bar_width = max(10, int(width))
    report_interval = max(0.05, float(min_interval_s))
    started = time.monotonic()
    last_report = started - report_interval
    last_percent = -1
    finished = False

    def report(sent: int, total: int) -> None:
        nonlocal last_report, last_percent, finished

        total_count = max(0, int(total))
        sent_count = max(0, min(int(sent), total_count)) if total_count else 0
        complete = total_count == 0 or sent_count >= total_count
        percent = 100.0 if total_count == 0 else 100.0 * sent_count / total_count
        now = time.monotonic()
        percent_step = int(percent)
        should_report = (
            not finished
            and (
                sent_count == 0
                or complete
                or percent_step > last_percent
                or now - last_report >= report_interval
            )
        )
        if not should_report:
            return
        filled = int(round(bar_width * percent / 100.0))
        filled = max(0, min(bar_width, filled))
        bar = "#" * filled + "-" * (bar_width - filled)
        print(
            f"\r{label} DDR 上传 [{bar}] {percent:6.2f}% "
            f"({sent_count:,}/{total_count:,} 包)",
            end="",
            flush=True,
        )
        last_report = now
        last_percent = percent_step
        if complete:
            print(flush=True)
            finished = True

    def finish() -> None:
        nonlocal finished
        if not finished:
            print(flush=True)
            finished = True

    return report, finish


def configure_and_arm(
    device: Dr47Device,
    record: np.ndarray,
    *,
    label: str,
    rf_nco_frequency_ghz: float = RF_NCO_GHZ,
    gain: float = GAIN,
    channels: Sequence[int] = (1,),
    bulk_upload: bool = False,
) -> None:
    """配置指定 XY 通道、上传同一条有限波形并 ARM；不启用 loop。

    ``channels`` 中的通道共享同一份 IQ 记录和启动指令，因此一个外部
    Trigger 会同时启动所有选中的通道。默认 ``(1,)`` 保持现有单通道示例
    的行为；``bulk_upload=True`` 用于大记录的流式 DDR 上传。
    """

    selected_channels = tuple(int(channel) for channel in channels)
    if not selected_channels:
        raise ValueError("channels must contain at least one XY channel")
    if len(set(selected_channels)) != len(selected_channels):
        raise ValueError("channels must not contain duplicates")
    if any(channel < 1 or channel > 4 for channel in selected_channels):
        raise ValueError("channels must contain XY channels in 1..4")
    channel_mask = sum(1 << (channel - 1) for channel in selected_channels)

    print(
        f"{label} 上传有限波形：CH{','.join(str(channel) for channel in selected_channels)}，"
        f"RF NCO={rf_nco_frequency_ghz:g} GHz，记录={len(record) // 2} 个 IQ 样本，"
        "loop=False"
    )
    plans = {}
    for channel in selected_channels:
        plans[channel] = device.set_xy_target_frequency(channel, rf_nco_frequency_ghz)
        device.set_gain("xy", channel, gain, gain_type="norm")
        device.set_qc_on_off("xy", channel, "on")
    for channel, plan in plans.items():
        print(
            f"{label} CH{channel} RF 目标={plan['target_rf_ghz']:g} GHz，"
            f"NCO={plan['nco_ghz']:g} GHz，Nyquist zone={plan['nyquist_zone']}"
        )
    device.commit()
    channel_waves = {channel: record for channel in selected_channels}
    report_upload, finish_upload = _make_upload_progress(label)
    try:
        device.upload_waveforms(
            channel_waves,
            wave_formats={channel: "interleaved_iq" for channel in selected_channels},
            auto_start=False,
            loop=False,
            channel_delays={channel: 0 for channel in selected_channels},
            instruction_repeats=3,
            bulk_upload=bulk_upload,
            progress_callback=report_upload,
        )
    finally:
        finish_upload()
    device.arm(channel_mask=channel_mask)
    wait_state(device, PlaybackState.PREPARED, f"{label} ARM")
    print(
        f"{label} CH{','.join(str(channel) for channel in selected_channels)} "
        "已进入 PREPARED；等待下一次 Trigger"
    )


def wait_counter(
    device: Dr47Device,
    attribute: str,
    before: int,
    label: str,
    timeout_s: float = 5.0,
) -> int:
    """等待硬件计数器增加，避免短暂 RUNNING 被 STATUS 轮询错过。"""

    deadline = time.monotonic() + timeout_s
    current = int(before)
    while time.monotonic() < deadline:
        caps = device.status(refresh=True).capabilities
        current = int(getattr(caps, attribute))
        if current > before:
            print(f"{label}: {before} -> {current}")
            return current
        time.sleep(POLL_INTERVAL_S)
    raise AssertionError(f"{label} 未增加，仍为 {current}")


def cleanup(*devices: Dr47Device | None) -> None:
    """按从卡到主卡顺序尽力停止并静音。"""

    for device in devices:
        if device is None:
            continue
        try:
            if device.connected:
                device.abort_mute()
        except DriverError:
            pass
        device.close()


__all__ = [
    "AMPLITUDE",
    "BOARD_PORT",
    "CHANNEL_MASK",
    "CONTROL_SOURCE_IP",
    "DISCOVERY_BROADCAST_IP",
    "DISCOVERY_SOURCE_CIDR",
    "DISCOVERY_SOURCE_IP",
    "GAIN",
    "MASTER_DEVICE_UID",
    "MASTER_MATCH_MAC",
    "MASTER_TARGET_IP",
    "MASTER_TARGET_MAC",
    "POLL_INTERVAL_S",
    "PULSE_DELAY_NS",
    "PULSE_DURATION_NS",
    "RECORD_DURATION_NS",
    "RF_NCO_GHZ",
    "SAMPLE_RATE_HZ",
    "SLAVE_DEVICE_UID",
    "SLAVE_MATCH_MAC",
    "SLAVE_TARGET_IP",
    "SLAVE_TARGET_MAC",
    "TARGET_GATEWAY",
    "TARGET_SUBNET_MASK",
    "UDP_INTERFACE",
    "BoardNetworkAssignment",
    "cleanup",
    "configure_and_arm",
    "enroll",
    "ensure_idle",
    "make_gaussian_burst_record",
    "make_gaussian_record",
    "new_device",
    "show_status",
    "wait_counter",
    "wait_rfdc_ready",
    "wait_state",
    "wait_until",
]
