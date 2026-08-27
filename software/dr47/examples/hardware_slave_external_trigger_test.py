"""从卡 external 模式的外部 Trigger 验收示例。

本脚本用于验证“从卡不 bypass，先收到真实 XS20 SYNC，再等待/接收 XS19
Trigger”的正式路径。脚本顶部的 ``TRIGGER_SOURCE`` 控制两种现场接线：

* ``external_input``：ARM 后等待外部设备从 XS19 输入 Trigger；脚本不会自行产生
  Trigger，适合主卡、国盾设备或其他 Trigger 源作为触发方的场景。
* ``xs18_loopback``：ARM 后调用 ``emit_trigger()``，从本卡 XS18 输出脉冲，经
  XS18 -> XS19 电缆回环后触发本卡；XS20 仍然必须先收到真实外部 SYNC。

两种模式都要求：

1. 板卡烧写正式 ``custom_xczu47dr_slave`` bitstream 和匹配固件；
2. XS17 接入与 bitstream 匹配的参考时钟；
3. XS20 已连接到外部 SYNC 源，并且该源已经产生一次有效上升沿；
4. ``external`` 模式下 ``sync_seen=True``、``sync_link_ready=True`` 后才 ARM。

本脚本不会调用 ``bypass_sync()``，也不会调用本地 UDP ``trigger()``。它验证的是
数字同步/Trigger 门控和播放状态；RF 频率、幅度、延迟和波形质量仍需仪器测量。

运行：

    PYTHONPATH=software python -m dr47.examples.hardware_slave_external_trigger_test

要测试 XS18 -> XS19 回环，只需把本文件顶部的 ``TRIGGER_SOURCE`` 改为
``"xs18_loopback"``，不需要命令行参数。
"""

from __future__ import annotations

import os
import time

import numpy as np

from ..capabilities import PlaybackState
from ..device import Dr47Device
from ..errors import DriverError
from ..hardware_test_network import BoardNetworkAssignment, discover_and_provision_boards
from ..waveforms import (
    iq_duration_to_interleaved_sample_count,
    make_iq_gaussian_sine_interleaved,
    place_interleaved_iq_in_record,
)


# 选择现场 Trigger 来源：external_input 或 xs18_loopback。
TRIGGER_SOURCE = "external_input"
EXTERNAL_TRIGGER_TIMEOUT_S = 30.0

# 网络配置直接写在代码中。使用交换机多板卡时，应填写目标 UID，避免按发现顺序猜板卡。
BOARD_PORT = 1234
UDP_INTERFACE = os.environ.get("RFSOC_UDP_INTERFACE", "enp1s0f0")
DISCOVERY_SOURCE_IP = os.environ.get("RFSOC_DISCOVERY_SOURCE_IP", "169.254.250.11")
DISCOVERY_SOURCE_CIDR = os.environ.get("RFSOC_DISCOVERY_SOURCE_CIDR", "169.254.250.11/16")
DISCOVERY_BROADCAST_IP = os.environ.get("RFSOC_DISCOVERY_BROADCAST_IP", "169.254.255.255")
CONTROL_SOURCE_IP = os.environ.get("RFSOC_CONTROL_SOURCE_IP", DISCOVERY_SOURCE_IP)
BOARD_TARGET_IP = "169.254.100.102"
TARGET_SUBNET_MASK = "255.255.0.0"
TARGET_GATEWAY = "0.0.0.0"
BOARD_DEVICE_UID = ""
BOARD_TARGET_MAC = None

# 示例波形：1 GHz RF NCO、60 ns 高斯包络、记录内延迟 100 ns。
RF_NCO_GHZ = 1.0
BASEBAND_GHZ = 0.0
PULSE_DURATION_NS = 60.0
PULSE_DELAY_NS = 100.0
RECORD_DURATION_NS = 10_000.0
AMPLITUDE = 1.0
GAIN = 1.0
SAMPLE_RATE_HZ = 400_000_000.0


def _status(device: Dr47Device, label: str):
    """刷新并打印同步、Trigger 计数和播放状态。"""

    status = device.status(refresh=True)
    caps = status.capabilities
    print(
        f"{label}: 状态={status.state.value}, 角色={caps.sync_role}, "
        f"模式={caps.sync_mode}, XS20已见={caps.sync_seen}, "
        f"Trigger门控={caps.sync_link_ready}, "
        f"Trigger(输入/接受/输出)={caps.trigger_input_count}/"
        f"{caps.trigger_accepted_count}/{caps.trigger_output_count}"
    )
    return status


def _wait_state(device: Dr47Device, expected: PlaybackState, label: str) -> None:
    """等待板卡状态，避免把命令 ACK 当作已经开始播放。"""

    deadline = time.monotonic() + 5.0
    last = None
    while time.monotonic() < deadline:
        last = device.status(refresh=True)
        if last.state is expected:
            return
        time.sleep(0.02)
    actual = "未知" if last is None else last.state.value
    raise AssertionError(f"{label}超时：期望 {expected.value}，实际 {actual}")


def _wait_external_sync(device: Dr47Device) -> None:
    """等待真实 XS20 SYNC；超时明确提示不能用 bypass 代替。"""

    print("等待 XS20 外部 SYNC；本测试不会调用 bypass_sync()")
    deadline = time.monotonic() + EXTERNAL_TRIGGER_TIMEOUT_S
    last = None
    while time.monotonic() < deadline:
        last = _status(device, "等待 SYNC")
        caps = last.capabilities
        if caps.sync_seen and caps.sync_link_ready:
            print("PASS: 从卡已在 external 模式观察到真实 XS20 SYNC")
            return
        time.sleep(0.2)
    raise AssertionError(
        "等待 XS20 SYNC 超时；请检查外部同步源、XS20 接线和电平，"
        "本脚本不使用 bypass_sync()"
    )


def _make_gaussian_record() -> np.ndarray:
    """生成上传到 CH1 的延迟高斯 IQ 记录。"""

    duration_s = PULSE_DURATION_NS * 1e-9
    active_count = iq_duration_to_interleaved_sample_count(duration_s, SAMPLE_RATE_HZ)
    active = make_iq_gaussian_sine_interleaved(
        frequency_hz=BASEBAND_GHZ * 1e9,
        phase_rad=0.0,
        amplitude=round(AMPLITUDE * 32767.0),
        sample_rate_hz=SAMPLE_RATE_HZ,
        duration_s=duration_s,
        sample_count=active_count,
        fwhm_s=duration_s / 2.0,
        q_sign=-1,
        hls_xy_drag=False,
    )
    return place_interleaved_iq_in_record(
        active,
        delay_s=PULSE_DELAY_NS * 1e-9,
        record_duration_s=RECORD_DURATION_NS * 1e-9,
        sample_rate_hz=SAMPLE_RATE_HZ,
    )


def _prepare(device: Dr47Device) -> None:
    """配置 RFDC、上传等待 Trigger 的波形并 ARM。"""

    iq = _make_gaussian_record()
    print(
        f"配置波形：RF NCO={RF_NCO_GHZ:g} GHz，基带={BASEBAND_GHZ:g} GHz，"
        f"高斯={PULSE_DURATION_NS:g} ns，记录内延迟={PULSE_DELAY_NS:g} ns，"
        f"记录={RECORD_DURATION_NS:g} ns"
    )
    device.set_xy_nco_frequency(1, RF_NCO_GHZ)
    device.set_gain("xy", 1, GAIN, gain_type="norm")
    device.set_qc_on_off("xy", 1, "on")
    device.commit()
    device.upload_waveforms(
        {1: iq},
        wave_formats={1: "interleaved_iq"},
        auto_start=False,
        loop=True,
        channel_delays={1: 0},
        instruction_repeats=3,
    )
    device.arm(channel_mask=0x01)
    _wait_state(device, PlaybackState.PREPARED, "ARM 后等待 PREPARED")


def _wait_for_external_trigger(device: Dr47Device, before_count: int) -> None:
    """等待 XS19 接收并接受一个真实外部 Trigger。"""

    print(
        f"已 ARM，等待 XS19 外部 Trigger，最长 {EXTERNAL_TRIGGER_TIMEOUT_S:g} s；"
        "请由外部设备输出一个上升沿"
    )
    deadline = time.monotonic() + EXTERNAL_TRIGGER_TIMEOUT_S
    while time.monotonic() < deadline:
        status = _status(device, "等待 XS19 Trigger")
        if status.capabilities.trigger_accepted_count > before_count:
            if status.state is not PlaybackState.RUNNING:
                raise AssertionError("XS19 Trigger 已被计数，但播放没有进入 RUNNING")
            print("PASS: 从卡 external 模式接受了 XS19 外部 Trigger")
            return
        time.sleep(0.1)
    raise AssertionError("等待 XS19 外部 Trigger 超时；请检查外部触发源和 XS19 接线")


def _run_loopback_trigger(device: Dr47Device, before_count: int, before_output: int) -> None:
    """由 XS18 输出脉冲，经 XS18 -> XS19 回环触发本卡。"""

    print("通过 XS18 -> XS19 回环输出物理 Trigger")
    device.emit_trigger()
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        status = _status(device, "等待 XS18 -> XS19 回环")
        caps = status.capabilities
        if caps.trigger_accepted_count > before_count:
            if caps.trigger_output_count <= before_output:
                raise AssertionError("回环已接受 Trigger，但 XS18 输出计数没有增加")
            if status.state is not PlaybackState.RUNNING:
                raise AssertionError("回环已接受 Trigger，但播放没有进入 RUNNING")
            print("PASS: external 模式下 XS18 -> XS19 回环触发播放")
            return
        time.sleep(0.05)
    raise AssertionError("XS18 -> XS19 回环后未观察到 XS19 接受计数")


def run() -> int:
    """执行从卡 external 模式验收。"""

    if TRIGGER_SOURCE not in {"external_input", "xs18_loopback"}:
        print(f"FAIL: 不支持的 TRIGGER_SOURCE={TRIGGER_SOURCE!r}")
        return 2

    device = None
    try:
        enrolled = discover_and_provision_boards(
            [
                BoardNetworkAssignment(
                    label="从卡",
                    sync_role="slave",
                    ip=BOARD_TARGET_IP,
                    device_uid=BOARD_DEVICE_UID,
                    mac=BOARD_TARGET_MAC,
                    subnet_mask=TARGET_SUBNET_MASK,
                    gateway=TARGET_GATEWAY,
                )
            ],
            interface=UDP_INTERFACE,
            discovery_source_ip=DISCOVERY_SOURCE_IP,
            discovery_source_cidr=DISCOVERY_SOURCE_CIDR,
            control_source_ip=CONTROL_SOURCE_IP,
            broadcast_ip=DISCOVERY_BROADCAST_IP,
            port=BOARD_PORT,
        )[0]
        device = Dr47Device(
            ip=enrolled.ip,
            port=BOARD_PORT,
            udp_interface=UDP_INTERFACE,
            udp_source_ip=CONTROL_SOURCE_IP,
            timeout_s=1.0,
            retries=2,
            batch_mode=True,
        )
        print(f"连接从卡 {enrolled.ip}:{BOARD_PORT}，UID={enrolled.device_uid}")
        device.connect()
        initial = _status(device, "初始状态")
        caps = initial.capabilities
        if caps.sync_role != "slave":
            raise AssertionError(f"当前 bitstream 不是从卡，实际角色为 {caps.sync_role!r}")
        if not (caps.rfdc_ready and caps.dac_mts_ready and caps.nco_sync_ready):
            raise AssertionError("RFDC、DAC MTS 或 NCO SYSREF 尚未就绪")
        if initial.state is not PlaybackState.IDLE:
            device.abort_mute()
            _wait_state(device, PlaybackState.IDLE, "清理旧播放状态")

        # 关键点：只要求 external，不启用 bypass；接下来必须看到真实 XS20 SYNC。
        device.require_external_sync()
        _wait_external_sync(device)
        _prepare(device)
        prepared = _status(device, "external 模式 ARM 后")
        before = prepared.capabilities

        if TRIGGER_SOURCE == "external_input":
            _wait_for_external_trigger(device, before.trigger_accepted_count)
        else:
            _run_loopback_trigger(
                device,
                before.trigger_accepted_count,
                before.trigger_output_count,
            )
        print("提示：请使用示波器或频谱仪确认 RF 输出频率、幅度和脉冲延迟")
        time.sleep(1.0)
        return 0
    except (DriverError, AssertionError) as error:
        print(f"FAIL: {type(error).__name__}: {error}")
        return 2
    finally:
        try:
            if device is not None and device.connected:
                device.abort_mute()
        except DriverError:
            pass
        if device is not None:
            device.close()


if __name__ == "__main__":
    raise SystemExit(run())
