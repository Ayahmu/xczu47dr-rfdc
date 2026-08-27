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

运行前请确认服务器通过 ``enp1s0f0`` 接入交换机，交换机再分别连接两块板卡，
并配置下面的发现源地址：

    sudo ip link set enp1s0f0 up
    sudo ip address replace 169.254.250.11/16 dev enp1s0f0
    sudo ip route replace 169.254.0.0/16 dev enp1s0f0 src 169.254.250.11

烧写后的 bitstream 会用 FPGA DNA 生成不同的临时 IP。脚本会在一次广播发现中
按 bitstream 固定的 ``master``/``slave`` 角色选板，自动分配正式 IP，再完成同步发波。
如果仍看到相同临时 IP，说明板卡还在运行旧 bitstream，必须重新烧写最新的
``artifacts/custom_xczu47dr_{master,slave}.bit``。

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
from ..hardware_test_network import (
    BoardNetworkAssignment,
    discover_and_provision_boards,
)
from ..sequence import make_trigger_sequence
from ..sync_group import SyncGroup
from ..waveforms import (
    iq_duration_to_interleaved_sample_count,
    make_iq_gaussian_sine_interleaved,
    place_interleaved_iq_in_record,
)


# 主机通过一个交换机端口连接两块板；一次广播发现后按固定 bitstream 角色选择。
BOARD_PORT = 1234
NETWORK_INTERFACE = "enp1s0f0"
DISCOVERY_SOURCE_IP = "169.254.250.11"
DISCOVERY_SOURCE_CIDR = "169.254.250.11/16"
CONTROL_SOURCE_IP = "169.254.250.11"
DISCOVERY_BROADCAST_IP = "169.254.255.255"

MASTER_TARGET_IP = "169.254.100.101"
SLAVE_TARGET_IP = "169.254.100.102"
TARGET_SUBNET_MASK = "255.255.0.0"
TARGET_GATEWAY = "0.0.0.0"

# 交换机上若接入额外同角色板卡，填写 UID/MAC 才能避免误选。
MASTER_DEVICE_UID = ""
SLAVE_DEVICE_UID = ""
MASTER_MATCH_MAC = ""
SLAVE_MATCH_MAC = ""
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


def _new_device(ip: str) -> Dr47Device:
    """创建绑定到指定 10G 网口的板卡驱动对象。"""

    return Dr47Device(
        ip=ip,
        port=BOARD_PORT,
        udp_interface=NETWORK_INTERFACE,
        udp_source_ip=CONTROL_SOURCE_IP,
        timeout_s=1.0,
        retries=2,
        batch_mode=True,
    )


def _wait_rfdc_ready(device: Dr47Device, label: str) -> None:
    """等待固件完成 RFDC、DAC MTS、NCO SYSREF 启动初始化。

    烧写后固件会先配置 HMC7044，再初始化 RFDC，并完成一次 DAC MTS 与
    NCO SYSREF 对齐。只有这三个状态都置位后才能安全下发 RFDC 配置；
    若 MTS 失败则直接抛出带错误码的断言，而不是继续静默等待。
    """

    deadline = time.monotonic() + 30.0
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
        time.sleep(0.05)
    caps = None if last is None else last.capabilities
    if caps is None:
        raise AssertionError(f"{label} 未返回 RFDC 状态")
    raise AssertionError(
        f"{label} RFDC 未就绪：rfdc_ready={caps.rfdc_ready}, "
        f"dac_mts_ready={caps.dac_mts_ready}, nco_sync_ready={caps.nco_sync_ready}"
    )


def _wait_prepared(device: Dr47Device, label: str) -> None:
    """等待 ARM 命令穿透到 DAC 时钟域并进入 PREPARED 状态。

    ARM 和 TRIGGER 都要跨越 DDR/DAC 两个时钟域，状态回读有几毫秒抖动；
    这里轮询真实硬件状态，而不是只相信命令 ACK。
    """

    deadline = time.monotonic() + 5.0
    last = None
    while time.monotonic() < deadline:
        last = device.status(refresh=True)
        if last.state is PlaybackState.PREPARED:
            return
        time.sleep(0.02)
    actual = "unknown" if last is None else last.state.value
    raise AssertionError(f"{label} ARM 未进入 PREPARED，实际状态={actual}")


def _wait_waveform_config(device: Dr47Device, label: str) -> None:
    """等待 DDR 波形执行器接收 PLAY/END 并完成预取。

    上传波形后，执行器需要先校验播放指令、把数据预取进内部 FIFO，并把
    ``play_pending_valid`` 和 ``play_prefill_ready`` 拉高。这里同时检查
    ``play_bad_instr_count``，避免无效指令被静默忽略后继续测试。
    """

    deadline = time.monotonic() + 10.0
    last = None
    while time.monotonic() < deadline:
        last = device.status(refresh=True)
        caps = last.capabilities
        raw = caps.raw
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


def _configure_and_upload(device: Dr47Device, record: np.ndarray, label: str) -> None:
    """配置 CH1、上传等待 Trigger 的波形并等待 DDR 预取完成。"""

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
    _wait_waveform_config(device, label)
    print(f"{label}波形已上传并完成 DDR 预取，等待 SYNC")


def _arm_after_sync(device: Dr47Device, label: str) -> None:
    """同步完成后才 ARM，避免对齐事务清掉或竞争播放准备状态。"""

    device.arm(channel_mask=CHANNEL_MASK)
    status = device.status(refresh=True)
    if status.state not in {PlaybackState.PREPARED, PlaybackState.ARMED}:
        raise AssertionError(f"{label} ARM 后状态异常：{status.state.value}")
    _wait_prepared(device, label)
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
        enrolled = discover_and_provision_boards(
            [
                BoardNetworkAssignment(
                    label="082 主卡",
                    sync_role="master",
                    ip=MASTER_TARGET_IP,
                    device_uid=MASTER_DEVICE_UID,
                    mac=MASTER_TARGET_MAC,
                    match_mac=MASTER_MATCH_MAC,
                    subnet_mask=TARGET_SUBNET_MASK,
                    gateway=TARGET_GATEWAY,
                ),
                BoardNetworkAssignment(
                    label="081 从卡",
                    sync_role="slave",
                    ip=SLAVE_TARGET_IP,
                    device_uid=SLAVE_DEVICE_UID,
                    mac=SLAVE_TARGET_MAC,
                    match_mac=SLAVE_MATCH_MAC,
                    subnet_mask=TARGET_SUBNET_MASK,
                    gateway=TARGET_GATEWAY,
                ),
            ],
            interface=NETWORK_INTERFACE,
            discovery_source_ip=DISCOVERY_SOURCE_IP,
            discovery_source_cidr=DISCOVERY_SOURCE_CIDR,
            control_source_ip=CONTROL_SOURCE_IP,
            broadcast_ip=DISCOVERY_BROADCAST_IP,
            port=BOARD_PORT,
        )
        enrolled_by_role = {item.sync_role: item for item in enrolled}
        master_net = enrolled_by_role["master"]
        slave_net = enrolled_by_role["slave"]
        master = _new_device(master_net.ip)
        slave = _new_device(slave_net.ip)
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
        _wait_rfdc_ready(master, "082 主卡")
        _wait_rfdc_ready(slave, "081 从卡")
        _configure_and_upload(master, record, "082 主卡")
        _configure_and_upload(slave, record, "081 从卡")

        # 两卡仍为空闲状态，保留已预取的 PLAY/END 配置进行 XS20 同步。
        alignment = SyncGroup(master, slave, timeout_s=5.0, poll_interval_s=0.01).sync(
            epoch=1, abort_before_sync=False
        )
        print(
            f"SYNC 完成：master_epoch={alignment.master_alignment_epoch}，"
            f"slave_epoch={alignment.slave_alignment_epoch}"
        )
        _arm_after_sync(master, "082 主卡同步后")
        _arm_after_sync(slave, "081 从卡同步后")
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
