"""250 MHz 板级示例共用辅助函数。

本模块只服务于 ``software/dr47/examples`` 下的真实硬件示例，不是驱动公开
API。网络入网、波形生成和状态轮询集中在这里，避免三个正式入口逐渐产生
不一致的行为。
"""

from __future__ import annotations

import os
import time
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
    active = make_iq_gaussian_sine_interleaved(
        frequency_hz=float(baseband_frequency_ghz) * 1e9,
        phase_rad=float(phase_rad),
        amplitude=round(float(amplitude) * 32767.0),
        sample_rate_hz=sample_rate_hz,
        duration_s=duration_s,
        sample_count=active_count,
        fwhm_s=duration_s / 2.0,
        q_sign=-1,
        hls_xy_drag=False,
    )
    return place_interleaved_iq_in_record(
        active,
        delay_s=delay_s,
        record_duration_s=float(record_duration_ns) * 1e-9,
        sample_rate_hz=sample_rate_hz,
    )


def configure_and_arm(
    device: Dr47Device,
    record: np.ndarray,
    *,
    label: str,
    rf_nco_frequency_ghz: float = RF_NCO_GHZ,
    gain: float = GAIN,
) -> None:
    """配置 CH1、上传一次有限波形并 ARM；不启用 loop。"""

    print(
        f"{label} 上传有限波形：RF NCO={rf_nco_frequency_ghz:g} GHz，"
        f"记录={len(record) // 2} 个 IQ 样本，loop=False"
    )
    plan = device.set_xy_target_frequency(1, rf_nco_frequency_ghz)
    print(
        f"{label} RF 目标={plan['target_rf_ghz']:g} GHz，"
        f"NCO={plan['nco_ghz']:g} GHz，Nyquist zone={plan['nyquist_zone']}"
    )
    device.set_gain("xy", 1, gain, gain_type="norm")
    device.set_qc_on_off("xy", 1, "on")
    device.commit()
    device.upload_waveforms(
        {1: record},
        wave_formats={1: "interleaved_iq"},
        auto_start=False,
        loop=False,
        channel_delays={1: 0},
        instruction_repeats=3,
    )
    device.arm(channel_mask=CHANNEL_MASK)
    wait_state(device, PlaybackState.PREPARED, f"{label} ARM")
    print(f"{label} 已进入 PREPARED；等待下一次 Trigger")


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
    "make_gaussian_record",
    "new_device",
    "show_status",
    "wait_counter",
    "wait_rfdc_ready",
    "wait_state",
    "wait_until",
]
