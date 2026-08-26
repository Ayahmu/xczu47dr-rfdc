"""082 主卡与 081 从卡的单次原子 Trigger 高斯正弦测试。

测试拓扑固定为：

* 082（``210512180082``）烧写 master bitstream；
* 081（``210512180081``）烧写 slave bitstream；
* 两块板的 XS17 共享 10 MHz 参考时钟；
* 082 XS20 -> 081 XS20；082 XS18 -> 081 XS19；
* Python 只向主卡发送一次 RFCTRL2 ``TRIGGER``。

主卡 RTL 会把这一个 DDR 时钟域事件同时用于本地 DAC 播放和 XS18
Trigger 输出。从卡只通过 XS19 接收物理 Trigger，因此主从启动时间不再由
两条 UDP 命令之间的 Python 时间间隔决定。

运行前请确认服务器的两个 10G 网口已经配置为下面的源地址，并且分别直连
对应板卡：

    sudo ip address replace 169.254.250.12/16 dev enp1s0f1
    sudo ip route replace 169.254.0.0/16 dev enp1s0f1 src 169.254.250.12
    sudo ip address replace 169.254.250.11/16 dev enp1s0f0
    sudo ip route replace 169.254.0.0/16 dev enp1s0f0 src 169.254.250.11

运行：

    PYTHONPATH=software python -m dr47.examples.hardware_master_slave_gaussian_sine_test

网络和波形参数都在本文件顶部定义，不接受命令行参数。
"""

from __future__ import annotations

import time

import numpy as np

from ..capabilities import PlaybackState
from ..device import Dr47Device
from ..errors import DriverError
from ..network import DiscoveredBoard, discover_boards, connect_discovered, provision_board
from ..sequence import make_trigger_sequence
from ..sync_group import SyncGroup
from ..waveforms import (
    iq_duration_to_interleaved_sample_count,
    make_iq_gaussian_sine_interleaved,
    place_interleaved_iq_in_record,
)


# 每个网口只直连一块板，因此发现分别在两个接口上进行。
BOARD_PORT = 1234
MASTER_INTERFACE = "enp1s0f1"  # 082
MASTER_SOURCE_IP = "169.254.250.12"
MASTER_SOURCE_CIDR = "169.254.250.12/16"
SLAVE_INTERFACE = "enp1s0f0"  # 081
SLAVE_SOURCE_IP = "169.254.250.11"
SLAVE_SOURCE_CIDR = "169.254.250.11/16"
DISCOVERY_BROADCAST_IP = "169.254.255.255"

MASTER_TARGET_IP = "169.254.100.101"
SLAVE_TARGET_IP = "169.254.100.102"
TARGET_SUBNET_MASK = "255.255.0.0"
TARGET_GATEWAY = "0.0.0.0"

# 直连时每个接口理论上只有一块板；填写 UID 后可避免误选其他设备。
MASTER_DEVICE_UID = ""
SLAVE_DEVICE_UID = ""
MASTER_TARGET_MAC = None
SLAVE_TARGET_MAC = None

# 400 MS/s 复基带：RFDC NCO 产生 1 GHz，软件记录使用 0 Hz 基带。
SAMPLE_RATE_HZ = 400_000_000.0
RF_NCO_GHZ = 1.0
BASEBAND_GHZ = 0.0
PULSE_DURATION_NS = 60.0
PULSE_DELAY_NS = 100.0
RECORD_DURATION_NS = 512.0
WAVEFORM_AMPLITUDE = 0.2
GAIN = 0.2
CHANNEL_MASK = 0x01  # CH1 -> vout00


def _make_gaussian_record() -> np.ndarray:
    """生成两块板完全相同的、带前置延迟的高斯正弦 IQ 记录。"""

    duration_s = PULSE_DURATION_NS * 1e-9
    active_count = iq_duration_to_interleaved_sample_count(duration_s, SAMPLE_RATE_HZ)
    active = make_iq_gaussian_sine_interleaved(
        frequency_hz=BASEBAND_GHZ * 1e9,
        phase_rad=0.0,
        amplitude=round(WAVEFORM_AMPLITUDE * 32767.0),
        sample_rate_hz=SAMPLE_RATE_HZ,
        duration_s=duration_s,
        sample_count=active_count,
        fwhm_s=duration_s / 2.0,
        q_sign=-1,
    )
    return place_interleaved_iq_in_record(
        active,
        delay_s=PULSE_DELAY_NS * 1e-9,
        record_duration_s=RECORD_DURATION_NS * 1e-9,
        sample_rate_hz=SAMPLE_RATE_HZ,
    )


def _discover_one(
    *,
    label: str,
    role: str,
    interface: str,
    source_ip: str,
    source_cidr: str,
    target_ip: str,
    device_uid: str,
    target_mac: str | None,
) -> tuple[str, str]:
    """在指定直连接口发现、确认角色并配置一块板卡的正式 IP。"""

    print(f"{label}：通过 {interface} 从 {source_ip} 广播 NETWORK_GET")
    boards = discover_boards(
        interface=interface,
        source_ip=source_ip,
        source_cidr=source_cidr,
        broadcast_ip=DISCOVERY_BROADCAST_IP,
        port=BOARD_PORT,
        timeout_s=1.0,
        rounds=3,
    )
    candidates: list[DiscoveredBoard] = []
    for board in boards:
        device = connect_discovered(board, timeout_s=1.0, retries=2)
        try:
            caps = device.status(refresh=False).capabilities
            print(
                f"发现 {label} 候选：UID={board.device_uid}，临时IP={board.current_ip}，"
                f"角色={caps.sync_role}"
            )
            if caps.sync_role == role and (
                not device_uid or board.device_uid.lower() == device_uid.lower()
            ):
                candidates.append(board)
        finally:
            device.close()
    if len(candidates) != 1:
        raise DriverError(
            f"{label} 应发现唯一 {role} 板卡，实际候选数={len(candidates)}"
        )
    board = candidates[0]
    print(f"配置{label}：{board.current_ip} -> {target_ip}")
    result = provision_board(
        board,
        ip=target_ip,
        mac=target_mac,
        subnet_mask=TARGET_SUBNET_MASK,
        gateway=TARGET_GATEWAY,
        port=BOARD_PORT,
        known_boards=boards,
        verification_source_ip=source_ip,
    )
    print(f"{label}配置完成：UID={result.device_uid}，IP={result.ip}")
    return result.ip, result.device_uid


def _new_device(ip: str, interface: str, source_ip: str) -> Dr47Device:
    """创建绑定到指定 10G 网口的板卡驱动对象。"""

    return Dr47Device(
        ip=ip,
        port=BOARD_PORT,
        udp_interface=interface,
        udp_source_ip=source_ip,
        timeout_s=1.0,
        retries=2,
        batch_mode=True,
    )


def _configure_and_arm(device: Dr47Device, record: np.ndarray, label: str) -> None:
    """配置 CH1、上传一次性等待 Trigger 的记录并 ARM。"""

    device.set_xy_nco_frequency(1, RF_NCO_GHZ)
    device.set_gain("xy", 1, GAIN, gain_type="norm")
    device.set_qc_on_off("xy", 1, "on")
    device.commit()
    device.upload_waveforms(
        {1: record},
        channel_sequences={1: make_trigger_sequence(int(record.size // 2))},
        wave_formats={1: "interleaved_iq"},
        auto_start=False,
        loop=False,
        instruction_repeats=1,
    )
    device.arm(channel_mask=CHANNEL_MASK)
    status = device.status(refresh=True)
    if status.state not in {PlaybackState.PREPARED, PlaybackState.ARMED}:
        raise AssertionError(f"{label} ARM 后状态异常：{status.state.value}")
    print(f"{label}已 ARM，等待物理 Trigger")


def _wait_counter(device: Dr47Device, attr: str, before: int, label: str) -> None:
    """等待指定计数增加，避免短脉冲播放状态被轮询错过。"""

    deadline = time.monotonic() + 3.0
    last = before
    while time.monotonic() < deadline:
        caps = device.status(refresh=True).capabilities
        last = int(getattr(caps, attr))
        if last > before:
            print(f"{label}：{before} -> {last}")
            return
        time.sleep(0.01)
    raise AssertionError(f"{label}计数未增加，仍为 {last}")


def run() -> int:
    """完成发现、配置、同步、一次原子 Trigger 和清理。"""

    record = _make_gaussian_record()
    master = slave = None
    try:
        master_ip, _ = _discover_one(
            label="082 主卡", role="master", interface=MASTER_INTERFACE,
            source_ip=MASTER_SOURCE_IP, source_cidr=MASTER_SOURCE_CIDR,
            target_ip=MASTER_TARGET_IP, device_uid=MASTER_DEVICE_UID,
            target_mac=MASTER_TARGET_MAC,
        )
        slave_ip, _ = _discover_one(
            label="081 从卡", role="slave", interface=SLAVE_INTERFACE,
            source_ip=SLAVE_SOURCE_IP, source_cidr=SLAVE_SOURCE_CIDR,
            target_ip=SLAVE_TARGET_IP, device_uid=SLAVE_DEVICE_UID,
            target_mac=SLAVE_TARGET_MAC,
        )
        master = _new_device(master_ip, MASTER_INTERFACE, MASTER_SOURCE_IP)
        slave = _new_device(slave_ip, SLAVE_INTERFACE, SLAVE_SOURCE_IP)
        master.connect()
        slave.connect()
        master.require_external_sync()
        slave.require_external_sync()
        master_caps = master.status(refresh=True).capabilities
        slave_caps = slave.status(refresh=True).capabilities
        if master_caps.sync_role != "master" or slave_caps.sync_role != "slave":
            raise AssertionError(
                f"角色错误：主卡={master_caps.sync_role}，从卡={slave_caps.sync_role}"
            )
        _configure_and_arm(master, record, "082 主卡")
        _configure_and_arm(slave, record, "081 从卡")

        # 先完成一次严格 XS20 同步；SyncGroup 会自动 ABORT/MUTE，随后必须 ARM。
        alignment = SyncGroup(master, slave, timeout_s=5.0, poll_interval_s=0.01).sync(epoch=1)
        print(
            f"SYNC 完成：master_epoch={alignment.master_alignment_epoch}，"
            f"slave_epoch={alignment.slave_alignment_epoch}"
        )
        master.arm(channel_mask=CHANNEL_MASK)
        slave.arm(channel_mask=CHANNEL_MASK)
        master_before = master.status(refresh=True).capabilities
        slave_before = slave.status(refresh=True).capabilities

        # 唯一一次播放触发。RTL 同时启动主卡本地播放并发出 XS18 脉冲。
        master.trigger()
        _wait_counter(master, "trigger_output_count", master_before.trigger_output_count, "082 XS18 输出")
        _wait_counter(slave, "trigger_accepted_count", slave_before.trigger_accepted_count, "081 XS19 接受")
        print(
            "PASS：082 主卡和 081 从卡各完成一次高斯正弦播放；"
            "主卡仅发送一次 RFCTRL2 TRIGGER，未调用 EMIT_TRIGGER。"
        )
        print("请用差分 RF 探头分别测量 CH1/vout00 的波形起点和相位差。")
        return 0
    except (DriverError, AssertionError) as error:
        print(f"FAIL: {type(error).__name__}: {error}")
        return 2
    finally:
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
