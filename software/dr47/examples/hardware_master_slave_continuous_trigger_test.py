"""082 主卡持续触发 / 081 从卡受触发循环发波的验证脚本（纯软件，不改硬件）。

背景：

之前的单次 ``master.trigger()`` 只让主卡进入 RUNNING，从卡虽然
``trigger_accepted_count`` 在增长，却一直停在 ARMED 不启动。本脚本不改
bitstream / RTL，只从驱动侧持续调用 trigger，验证：

1. 主卡每次 ``trigger()`` 是否都能真正发出 XS18 脉冲；
2. 从卡在连续触发下是否最终进入 RUNNING 并保持循环。

重要硬件约束（已从 RTL 确认）：

``RF2_OP_TRIGGER`` 命令要求 ``playback_prepared == 1``。loop 波形在第一次
trigger 之后 ``prepared`` 会变为 0，因此后续 ``trigger()`` 会被硬件以
``0x0006 (UNSAFE_STATE)`` 拒绝。``EMIT_TRIGGER`` 不受 ``prepared`` 门控，
可以连续发出 XS18 脉冲。因此脚本先调用一次 ``trigger()`` 启动主卡，之后用
``emit_trigger()`` 持续产生 XS18 脉冲。

运行：

    PYTHONPATH=software python -m dr47.examples.hardware_master_slave_continuous_trigger_test
"""

from __future__ import annotations

import time

import numpy as np

from ..capabilities import PlaybackState
from ..device import Dr47Device
from ..errors import DeviceStatusError, DriverError
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

MASTER_DEVICE_UID = ""
SLAVE_DEVICE_UID = ""
MASTER_MATCH_MAC = ""
SLAVE_MATCH_MAC = ""
MASTER_TARGET_MAC = None
SLAVE_TARGET_MAC = None

# 当两块板卡已经处在目标 IP（例如上一次测试已配置且未断电）时，设为 True
# 可跳过广播发现和 NETWORK_APPLY，直接连接，避免重复配置被 0x0006 拒绝。
DIRECT_CONNECT = True

SAMPLE_RATE_HZ = 400_000_000.0
RF_NCO_GHZ = 1.0
BASEBAND_GHZ = 0.0
PULSE_DURATION_NS = 60.0
PULSE_DELAY_NS = 100.0
RECORD_DURATION_NS = 512.0
WAVEFORM_AMPLITUDE = 0.2
GAIN = 0.2
CHANNEL_MASK = 0x01  # CH1 -> vout00

# 持续触发阶段：每次脉冲之间的间隔和总持续时间。
TRIGGER_INTERVAL_S = 0.01
TRIGGER_PHASE_S = 5.0


def _make_gaussian_record() -> np.ndarray:
    """生成带前置延迟的 1 GHz 高斯正弦 IQ 记录。

    RFDC NCO 产生 1 GHz 射频载波，软件记录使用 0 Hz 基带高斯包络；
    记录开头预留 100 ns 零值延迟，便于示波器/ILA 定位波形起点。
    """

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
    """创建绑定到指定 10G 网口与控制源地址的板卡驱动对象。"""

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
    """等待固件完成 RFDC / DAC MTS / NCO SYSREF 启动初始化。"""

    deadline = time.monotonic() + 30.0
    last = None
    while time.monotonic() < deadline:
        last = device.status(refresh=True)
        caps = last.capabilities
        if caps.rfdc_ready and caps.dac_mts_ready and caps.nco_sync_ready:
            return
        if caps.dac_mts_failed:
            raise AssertionError(f"{label} DAC MTS 失败：error=0x{caps.dac_mts_error:04X}")
        time.sleep(0.05)
    raise AssertionError(f"{label} RFDC 未就绪")


def _wait_prepared(device: Dr47Device, label: str) -> None:
    """等待板卡进入 PREPARED，而不是只相信 ARM 命令 ACK。"""

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
    """等待 DDR 执行器接收 PLAY/END 并完成波形预取。"""

    deadline = time.monotonic() + 10.0
    last = None
    while time.monotonic() < deadline:
        last = device.status(refresh=True)
        raw = last.capabilities.raw
        channel_mask = int(raw.get("play_config_channel_mask", 0)) & 0xFF
        pending = bool(raw.get("play_pending_valid", False))
        prefill = bool(raw.get("play_prefill_ready", False))
        if (channel_mask & CHANNEL_MASK) == CHANNEL_MASK and pending and prefill:
            return
        time.sleep(0.02)
    raise AssertionError(f"{label} 波形配置未就绪")


def _configure_and_upload(device: Dr47Device, record: np.ndarray, label: str) -> None:
    """配置 CH1、上传等待 Trigger 的波形并等待 DDR 预取。"""

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
    print(f"{label}波形已上传并完成 DDR 预取")


def _snapshot(device: Dr47Device, label: str) -> str:
    """刷新并格式化一块板卡的播放与同步状态，便于打印对照。"""

    caps = device.status(refresh=True).capabilities
    return (
        f"{label}: state={caps.playback_state.value}, "
        f"running={caps.playback_running}, prepared={caps.playback_prepared}, "
        f"trigger_in={caps.trigger_input_count}, "
        f"trigger_acc={caps.trigger_accepted_count}, "
        f"sync_link_ready={caps.sync_link_ready}"
    )


def run() -> int:
    """执行主卡持续触发、从卡受触发循环发波的完整验收流程。"""

    record = _make_gaussian_record()
    master = slave = None
    try:
        if DIRECT_CONNECT:
            master = _new_device(MASTER_TARGET_IP)
            slave = _new_device(SLAVE_TARGET_IP)
        else:
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
            master = _new_device(enrolled_by_role["master"].ip)
            slave = _new_device(enrolled_by_role["slave"].ip)
        master.connect()
        slave.connect()

        # 清掉上一次测试残留的 armed/prepared/running 状态，避免
        # SET_SYNC_ROLE 被 0x0003 拒绝。
        for device, label in ((master, "082 主卡"), (slave, "081 从卡")):
            try:
                device.abort_mute()
            except DriverError:
                pass
        master.require_external_sync()
        slave.require_external_sync()
        _wait_rfdc_ready(master, "082 主卡")
        _wait_rfdc_ready(slave, "081 从卡")

        alignment = SyncGroup(master, slave, timeout_s=15.0, poll_interval_s=0.01).sync(
            epoch=1, abort_before_sync=True
        )
        print(
            f"SYNC 完成：master_epoch={alignment.master_alignment_epoch}，"
            f"slave_epoch={alignment.slave_alignment_epoch}"
        )
        # SYNC 中的 RFDC reset 会恢复固件基线；运行参数和波形必须在同步后提交。
        _configure_and_upload(master, record, "082 主卡")
        _configure_and_upload(slave, record, "081 从卡")
        master.arm(channel_mask=CHANNEL_MASK)
        slave.arm(channel_mask=CHANNEL_MASK)
        _wait_prepared(master, "082 主卡")
        _wait_prepared(slave, "081 从卡")
        print("两块板卡均已 ARM / PREPARED")
        print(_snapshot(master, "主卡"))
        print(_snapshot(slave, "从卡"))

        # 第一次 trigger 启动主卡本地播放并发出第一个 XS18 脉冲。
        master.trigger()
        print("已发出第一次 master.trigger()")
        time.sleep(0.3)
        print(_snapshot(master, "主卡"))
        print(_snapshot(slave, "从卡"))

        # 持续触发阶段：trigger() 在 loop 模式第一次之后会被 0x0006 拒绝，
        # 因此捕获后改用 emit_trigger() 连续产生 XS18 脉冲。
        trigger_ok = 0
        emit_ok = 0
        trigger_rejected = 0
        deadline = time.monotonic() + TRIGGER_PHASE_S
        last_report = 0.0
        while time.monotonic() < deadline:
            try:
                master.trigger()
                trigger_ok += 1
            except DeviceStatusError as exc:
                trigger_rejected += 1
                master.emit_trigger()
                emit_ok += 1
            now = time.monotonic()
            if now - last_report >= 0.5:
                last_report = now
                print(_snapshot(master, "主卡"))
                print(_snapshot(slave, "从卡"))
            time.sleep(TRIGGER_INTERVAL_S)

        print(
            f"持续触发结束：trigger() 成功 {trigger_ok} 次，"
            f"被拒绝 {trigger_rejected} 次（改用 emit_trigger），"
            f"emit_trigger 成功 {emit_ok} 次"
        )
        print(_snapshot(master, "主卡"))
        print(_snapshot(slave, "从卡"))
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
