"""主卡 -> 从卡的完整同步与 Trigger 发波板级测试。

本脚本验证的是正式双卡链路，而不是单板旁路：

* 主卡使用 ``custom_xczu47dr_master``，从卡使用
  ``custom_xczu47dr_slave``；
* XS17 分别接入两块板卡要求的同一参考时钟；参考频率必须与 bitstream 匹配；
* 主卡 XS20 输出连接从卡 XS20 输入；
* 主卡 XS18（TRIG_1）连接从卡 XS19（TRIG_2）；
* 两块板卡都设置为 ``external``，使用 ``SyncGroup.sync(abort_before_sync=False)``；
* 两卡先完成波形上传和 DDR 预取，再由 ``SyncGroup`` 发出 XS20 SYNC 并等待
  两卡重新完成 DAC MTS/NCO 对齐；成功后脚本才 ARM；
* 主卡只使用一次 UDP ``trigger()``；主卡 RTL 同时通过 XS18/XS19
  启动本地和从卡播放。

这个 Trigger 是一个明确的 FPGA/DDR 时钟域事件，脚本用主卡输出计数和从卡
输入/接受计数验证两条硬件路径；它不宣称两块 DAC 的 RF 相位或时间偏差已经达到某个数值。
RF 频率、幅度、相位和同步精度仍必须用示波器/频谱仪测量。

运行：

    PYTHONPATH=software python -m dr47.examples.hardware_master_slave_wave_test

运行前修改本文件顶部的发现地址、主从目标 IP 和可选 ``device_uid``。脚本会先
广播发现板卡，再按 bitstream 上报的主从角色选择板卡、分配目标 IP 并回读验证；
它不接受命令行网络参数。
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
from ..sequence import make_trigger_sequence
from ..sync_group import SyncGroup


# 所有网络配置都集中在这里。主机网卡必须已经拥有对应的发现地址。
# 主从可以位于同一个交换机端口域，也可以各自直连独立的 10G 网口。
# 若改用 10.50.0.x 等正式网段，请先给主机网卡增加同网段地址，并同步修改
# 两组 CONTROL_SOURCE_IP、TARGET_SUBNET_MASK 和 TARGET_GATEWAY。
BOARD_PORT = 1234
MASTER_UDP_INTERFACE = os.environ.get("RFSOC_MASTER_UDP_INTERFACE", "enp1s0f0")
MASTER_DISCOVERY_SOURCE_IP = os.environ.get("RFSOC_MASTER_DISCOVERY_SOURCE_IP", "169.254.250.11")
MASTER_DISCOVERY_SOURCE_CIDR = os.environ.get("RFSOC_MASTER_DISCOVERY_SOURCE_CIDR", "169.254.250.11/16")
MASTER_CONTROL_SOURCE_IP = os.environ.get("RFSOC_MASTER_CONTROL_SOURCE_IP", MASTER_DISCOVERY_SOURCE_IP)

SLAVE_UDP_INTERFACE = os.environ.get("RFSOC_SLAVE_UDP_INTERFACE", "enp1s0f1")
SLAVE_DISCOVERY_SOURCE_IP = os.environ.get("RFSOC_SLAVE_DISCOVERY_SOURCE_IP", "169.254.250.12")
SLAVE_DISCOVERY_SOURCE_CIDR = os.environ.get("RFSOC_SLAVE_DISCOVERY_SOURCE_CIDR", "169.254.250.12/16")
SLAVE_CONTROL_SOURCE_IP = os.environ.get("RFSOC_SLAVE_CONTROL_SOURCE_IP", SLAVE_DISCOVERY_SOURCE_IP)

DISCOVERY_BROADCAST_IP = os.environ.get("RFSOC_DISCOVERY_BROADCAST_IP", "169.254.255.255")

MASTER_TARGET_IP = "169.254.100.101"
SLAVE_TARGET_IP = "169.254.100.102"
TARGET_SUBNET_MASK = "255.255.0.0"
TARGET_GATEWAY = "0.0.0.0"

# 留空时按实际 sync_role 自动选择。交换机后存在多块同角色板卡时必须填写。
MASTER_DEVICE_UID = ""
SLAVE_DEVICE_UID = ""
# None 表示保留 DNA 派生 MAC；也可以改成唯一的自定义单播 MAC。
MASTER_TARGET_MAC = None
SLAVE_TARGET_MAC = None

NCO_GHZ = 0.1
GAIN = 0.2
CHANNEL_MASK = 0x01


def _status(device: Dr47Device, label: str):
    """刷新并打印一块板的播放、同步和 Trigger 计数。"""

    status = device.status(refresh=True)
    caps = status.capabilities
    print(
        f"{label}: 状态={status.state.value}, 角色={caps.sync_role}, "
        f"模式={caps.sync_mode}, XS20已见={caps.sync_seen}, "
        f"同步门控={caps.sync_link_ready}, "
        f"Trigger(输入/接受/输出)={caps.trigger_input_count}/"
        f"{caps.trigger_accepted_count}/{caps.trigger_output_count}"
    )
    return status


def _wait_state(device: Dr47Device, expected: PlaybackState, label: str) -> None:
    """等待板卡上报目标状态，而不是只相信命令 ACK。"""

    deadline = time.monotonic() + 3.0
    last = None
    while time.monotonic() < deadline:
        last = device.status(refresh=True)
        if last.state is expected:
            return
        time.sleep(0.02)
    actual = "未知" if last is None else last.state.value
    raise AssertionError(f"{label}超时：期望 {expected.value}，实际 {actual}")


def _wait_slave_sync(slave: Dr47Device) -> None:
    """等待从卡在 XS20 上实际观察到主卡发出的同步边沿。"""

    deadline = time.monotonic() + 3.0
    last = None
    while time.monotonic() < deadline:
        last = slave.status(refresh=True)
        caps = last.capabilities
        if caps.sync_seen and caps.sync_link_ready:
            return
        time.sleep(0.02)
    raise AssertionError("从卡没有在 XS20 上观察到 SYNC；请检查 XS20 连接和电气方向")


def _wait_waveform_config(device: Dr47Device, label: str) -> None:
    """等待 DDR executor 接收 PLAY/END 并完成预取。"""

    deadline = time.monotonic() + 10.0
    last = None
    while time.monotonic() < deadline:
        last = device.status(refresh=True)
        raw = last.capabilities.raw
        channel_mask = int(raw.get("play_config_channel_mask", 0)) & 0xFF
        pending = bool(raw.get("play_pending_valid", False))
        prefill = bool(raw.get("play_prefill_ready", False))
        bad_instr = int(raw.get("play_bad_instr_count", 0))
        if (channel_mask & CHANNEL_MASK) == CHANNEL_MASK and pending and prefill:
            if bad_instr:
                raise AssertionError(f"{label} executor 拒绝了 {bad_instr} 条播放指令")
            return
        time.sleep(0.02)
    if last is None:
        raise AssertionError(f"{label} 未返回波形 executor 状态")
    raw = last.capabilities.raw
    raise AssertionError(
        f"{label} 波形配置未就绪：play_config_mask=0x{int(raw.get('play_config_channel_mask', 0)) & 0xFF:02X}, "
        f"pending={int(bool(raw.get('play_pending_valid', False)))}, "
        f"prefill={int(bool(raw.get('play_prefill_ready', False)))}, "
        f"bad_instr={int(raw.get('play_bad_instr_count', 0))}"
    )


def _configure_and_upload(device: Dr47Device, iq: np.ndarray, label: str) -> None:
    """配置 CH1、上传一个等待 Trigger 的波形序列并等待预取完成。"""

    # 该记录是 64 KiB 的交织 IQ：I=4096、Q=0，作为稳定的直流复包络。
    # 实际 RF 载波由 RFDC NCO 设置，避免把高 RF 频率错误地当成基带频率上传。
    device.set_xy_nco_frequency(1, NCO_GHZ)
    device.set_gain("xy", 1, GAIN, gain_type="norm")
    device.set_qc_on_off("xy", 1, "on")
    device.commit()
    device.upload_waveforms(
        {1: iq},
        channel_sequences={1: make_trigger_sequence(int(iq.size // 2))},
        wave_formats={1: "interleaved_iq"},
        auto_start=False,
        loop=False,
        instruction_repeats=3,
    )
    _wait_waveform_config(device, label)


def _arm_after_sync(device: Dr47Device, label: str) -> None:
    """同步后 ARM，避免对齐事务清除或竞争播放准备状态。"""

    device.arm(channel_mask=CHANNEL_MASK)
    _wait_state(device, PlaybackState.PREPARED, f"{label} ARM 后等待 PREPARED")


def _new_device(ip: str, interface: str, source_ip: str) -> Dr47Device:
    """创建统一网络参数的板卡对象。"""

    return Dr47Device(
        ip=ip,
        port=BOARD_PORT,
        udp_interface=interface,
        udp_source_ip=source_ip,
        timeout_s=1.0,
        retries=2,
        batch_mode=True,
    )


def run() -> int:
    """执行双卡同步、双卡 ARM、主卡本地发波和从卡物理 Trigger 发波。"""

    # 64 KiB 交织 IQ 记录：16384 个复样点，足够在 RUNNING 状态下观测。
    iq = np.zeros(32768, dtype="<i2")
    iq[::2] = 4096
    master = None
    slave = None
    try:
        master_enrolled = discover_and_provision_boards(
            [
                BoardNetworkAssignment(
                    label="主卡",
                    sync_role="master",
                    ip=MASTER_TARGET_IP,
                    device_uid=MASTER_DEVICE_UID,
                    mac=MASTER_TARGET_MAC,
                    subnet_mask=TARGET_SUBNET_MASK,
                    gateway=TARGET_GATEWAY,
                )
            ],
            interface=MASTER_UDP_INTERFACE,
            discovery_source_ip=MASTER_DISCOVERY_SOURCE_IP,
            discovery_source_cidr=MASTER_DISCOVERY_SOURCE_CIDR,
            control_source_ip=MASTER_CONTROL_SOURCE_IP,
            broadcast_ip=DISCOVERY_BROADCAST_IP,
            port=BOARD_PORT,
        )
        slave_enrolled = discover_and_provision_boards(
            [
                BoardNetworkAssignment(
                    label="从卡",
                    sync_role="slave",
                    ip=SLAVE_TARGET_IP,
                    device_uid=SLAVE_DEVICE_UID,
                    mac=SLAVE_TARGET_MAC,
                    subnet_mask=TARGET_SUBNET_MASK,
                    gateway=TARGET_GATEWAY,
                )
            ],
            interface=SLAVE_UDP_INTERFACE,
            discovery_source_ip=SLAVE_DISCOVERY_SOURCE_IP,
            discovery_source_cidr=SLAVE_DISCOVERY_SOURCE_CIDR,
            control_source_ip=SLAVE_CONTROL_SOURCE_IP,
            broadcast_ip=DISCOVERY_BROADCAST_IP,
            port=BOARD_PORT,
        )
        master_net = master_enrolled[0]
        slave_net = slave_enrolled[0]
        master = _new_device(master_net.ip, MASTER_UDP_INTERFACE, MASTER_CONTROL_SOURCE_IP)
        slave = _new_device(slave_net.ip, SLAVE_UDP_INTERFACE, SLAVE_CONTROL_SOURCE_IP)
        print(
            f"连接主卡 {master_net.ip}（{master_net.device_uid}）和从卡 "
            f"{slave_net.ip}（{slave_net.device_uid}），网卡 "
            f"{MASTER_UDP_INTERFACE}/{SLAVE_UDP_INTERFACE}"
        )
        master.connect()
        slave.connect()
        master_initial = _status(master, "主卡初始")
        slave_initial = _status(slave, "从卡初始")
        for label, status, role in (
            ("主卡", master_initial, "master"),
            ("从卡", slave_initial, "slave"),
        ):
            caps = status.capabilities
            if status.state is not PlaybackState.IDLE:
                print(f"{label}残留状态为 {status.state.value}，发送 ABORT_MUTE")
                (master if label == "主卡" else slave).abort_mute()
            if caps.sync_role != role:
                raise AssertionError(f"{label}角色错误：期望 {role}，实际 {caps.sync_role}")
            if not (caps.rfdc_ready and caps.dac_mts_ready and caps.nco_sync_ready):
                raise AssertionError(f"{label} RFDC/DAC MTS/NCO 尚未就绪")

        # 主从都使用严格 external 模式。从卡不会因为软件命令而伪造 sync_seen。
        master.require_external_sync()
        slave.require_external_sync()
        _status(master, "主卡 external 模式")
        _status(slave, "从卡 external 模式，等待 XS20")

        # 两卡先上传并预取，但保持 IDLE；同步事务不会清空这份配置。
        _configure_and_upload(master, iq, "主卡")
        _configure_and_upload(slave, iq, "从卡")

        # 主卡 XS20 输出一个同步边沿；从卡 XS20 输入收到后打开 Trigger 门控。
        alignment = SyncGroup(master, slave, timeout_s=5.0, poll_interval_s=0.01).sync(
            epoch=1, abort_before_sync=False
        )
        print(
            f"严格同步完成：master alignment_epoch={alignment.master_alignment_epoch}, "
            f"slave alignment_epoch={alignment.slave_alignment_epoch}, "
            f"elapsed={alignment.elapsed_s:.3f}s"
        )
        _arm_after_sync(master, "严格同步后主卡")
        _arm_after_sync(slave, "严格同步后从卡")

        # 记录一次触发前的计数。主卡只发送一个 RFCTRL2 TRIGGER；新的 RTL
        # 会在同一个 DDR 时钟域同时启动本地播放并产生 XS18 脉冲。
        master_before = master.status(refresh=True).capabilities
        slave_before = slave.status(refresh=True).capabilities
        master.trigger()
        _wait_state(master, PlaybackState.RUNNING, "主卡本地 UDP Trigger")
        _wait_state(slave, PlaybackState.RUNNING, "从卡 XS19 Trigger")
        master_after = _status(master, "主卡本地播放和 XS18 输出")
        slave_after = _status(slave, "从卡 XS19 物理 Trigger 播放")
        if master_after.capabilities.trigger_output_count <= master_before.trigger_output_count:
            raise AssertionError("主卡 XS18 输出计数没有增加")
        if slave_after.capabilities.trigger_input_count <= slave_before.trigger_input_count:
            raise AssertionError("从卡 XS19 输入计数没有增加")
        if slave_after.capabilities.trigger_accepted_count <= slave_before.trigger_accepted_count:
            raise AssertionError("从卡没有接受主卡发出的 Trigger")

        print(
            "PASS: 主卡 XS20->从卡 XS20 SYNC，以及一次主卡 RFCTRL2 TRIGGER"
            "同时启动主卡本地播放和 XS18->XS19 从卡播放均已通过。"
        )
        print("提示：两块板卡的 RF 频率、幅度和相位关系仍需仪器实测。")
        return 0
    except (DriverError, AssertionError) as error:
        print(f"FAIL: {type(error).__name__}: {error}")
        return 2
    finally:
        # 测试结束统一停止两块板卡，避免示波器端留下持续输出。
        for device in (slave, master):
            if device is None:
                continue
            try:
                if device.connected:
                    device.abort_mute()
            except DriverError:
                pass
            device.close()


if __name__ == "__main__":
    raise SystemExit(run())
