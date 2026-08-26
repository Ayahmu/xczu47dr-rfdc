"""主卡单卡完整发波测试。

本脚本不要求另一块板卡，也不要求 XS20 有外部接收端，更不要求 XS18/XS19
回环。主卡 bitstream 的设计角色本身允许本地播放，因此流程是：连接 -> 检查
RFDC 就绪 -> 配置 RFDC/NCO -> 上传循环 IQ -> ARM -> UDP ``trigger()`` ->
观察 RUNNING -> ABORT_MUTE。

``trigger()`` 是上位机发给本板的 UDP 软件 Trigger，不会在 XS18 产生电平。
本脚本不验证 XS18->XS19 的物理回环。完整的双卡 SYNC 和物理 Trigger
链路由 ``hardware_master_slave_wave_test`` 验证。

运行：

    PYTHONPATH=software python -m dr47.examples.hardware_master_standalone_wave_test

运行前在本文件顶部填写网络配置。脚本固定执行广播发现、主卡角色确认、目标 IP
分配和回读验证，不接受命令行网络参数。
"""

from __future__ import annotations

import os
import time

import numpy as np

from ..capabilities import PlaybackState
from ..device import Dr47Device
from ..errors import DriverError
from ..hardware_test_network import (
    BoardNetworkAssignment,
    discover_and_provision_boards,
)


# 所有网络参数都直接写在这里。目标 IP 改到其他子网时，还要给主机网卡增加
# 对应网段地址，并修改 CONTROL_SOURCE_IP、TARGET_SUBNET_MASK 和 TARGET_GATEWAY。
BOARD_PORT = 1234
UDP_INTERFACE = os.environ.get("RFSOC_UDP_INTERFACE", "enp11s0")
DISCOVERY_SOURCE_IP = os.environ.get("RFSOC_DISCOVERY_SOURCE_IP", "169.254.250.11")
DISCOVERY_SOURCE_CIDR = os.environ.get("RFSOC_DISCOVERY_SOURCE_CIDR", "169.254.250.11/16")
DISCOVERY_BROADCAST_IP = os.environ.get("RFSOC_DISCOVERY_BROADCAST_IP", "169.254.255.255")
CONTROL_SOURCE_IP = os.environ.get("RFSOC_CONTROL_SOURCE_IP", DISCOVERY_SOURCE_IP)

BOARD_TARGET_IP = "169.254.100.101"
TARGET_SUBNET_MASK = "255.255.0.0"
TARGET_GATEWAY = "0.0.0.0"
BOARD_DEVICE_UID = ""  # 多块主卡同时在线时必须填写目标 UID。
BOARD_TARGET_MAC = None  # None 表示保留 DNA 派生 MAC。


def _wait_state(device: Dr47Device, expected: PlaybackState, label: str) -> None:
    """读取板卡状态直到达到目标，避免把命令 ACK 当作播放证据。"""

    deadline = time.monotonic() + 3.0
    last = None
    while time.monotonic() < deadline:
        last = device.status(refresh=True)
        if last.state is expected:
            return
        time.sleep(0.02)
    actual = "未知" if last is None else last.state.value
    raise AssertionError(f"{label}超时：期望 {expected.value}，实际 {actual}")


def run() -> int:
    """执行主卡单卡本地连续波形的完整配置、播放和清理流程。"""

    device = None
    try:
        enrolled = discover_and_provision_boards(
            [
                BoardNetworkAssignment(
                    label="主卡",
                    sync_role="master",
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
        print(
            f"连接主卡 {enrolled.ip}:{BOARD_PORT}，UID={enrolled.device_uid}，"
            f"网卡 {UDP_INTERFACE}"
        )
        device.connect()
        initial = device.status(refresh=True)
        caps = initial.capabilities
        print(
            f"初始状态：{initial.state.value}，角色={caps.sync_role}，"
            f"同步门控={caps.sync_link_ready}，XS20已见={caps.sync_seen}"
        )
        if caps.sync_role != "master":
            raise AssertionError(f"当前 bitstream 不是主卡，实际角色为 {caps.sync_role!r}")
        if not (caps.rfdc_ready and caps.dac_mts_ready and caps.nco_sync_ready):
            raise AssertionError("RFDC、DAC MTS 或 NCO SYSREF 尚未就绪")
        if initial.state is not PlaybackState.IDLE:
            print("清理上一次残留播放：ABORT_MUTE")
            device.abort_mute()

        # 主卡无需先调用 sync()。这里保持 external 模式只是表明它仍可在
        # 后续实验中承担同步源角色；主卡的本地 Trigger 不受 XS20 门控。
        device.require_external_sync()
        status = device.status(refresh=True)
        if not status.capabilities.sync_link_ready:
            raise AssertionError("主卡在未同步时没有开放本地 Trigger 门控")

        # 64 KiB 交织 IQ 记录（I=4096,Q=0），使用 0.1 GHz NCO 作为射频目标。
        # loop=True 用于让 RUNNING 保持足够长，便于观察状态和连接示波器。
        iq = np.zeros(32768, dtype="<i2")
        iq[::2] = 4096
        device.set_xy_nco_frequency(1, 0.1)
        device.set_gain("xy", 1, 0.2, gain_type="norm")
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

        before = device.status(refresh=True).capabilities
        # 只发送 UDP trigger()；不调用 sync()，也不调用 emit_trigger()。
        device.trigger()
        _wait_state(device, PlaybackState.RUNNING, "主卡本地软件 Trigger")
        running = device.status(refresh=True)
        after = running.capabilities
        print(
            f"本地发波状态：{running.state.value}，XS20已见={after.sync_seen}，"
            f"Trigger(输入/接受/输出)={after.trigger_input_count}/"
            f"{after.trigger_accepted_count}/{after.trigger_output_count}"
        )
        if after.trigger_input_count != before.trigger_input_count:
            raise AssertionError("本地 UDP Trigger 不应增加物理输入计数")
        if after.trigger_output_count != before.trigger_output_count:
            raise AssertionError("本地 UDP Trigger 不应增加 XS18 输出计数")
        print("PASS: 主卡未调用 sync()，仍可通过本地 UDP Trigger 独立进入 RUNNING")
        print("提示：RF 频率、幅度和波形质量仍需使用示波器或频谱仪确认。")
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
