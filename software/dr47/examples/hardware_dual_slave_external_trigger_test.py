"""两块从卡等待外部 SYNC/Trigger 的板级测试示例。

本脚本适用于下面的现场拓扑：

* 两块板都烧写 ``custom_xczu47dr_slave`` bitstream；
* 两块板的 XS17 接同一个参考时钟；
* 外部同步源分别接到两块板的 XS20；
* 外部 Trigger 源分别接到两块板的 XS19（可由同一个 Trigger 分配器扇出）；
* 上位机只负责发现、配置网络、上传波形和 ARM，**不产生 SYNC 或 Trigger**。

运行脚本后，流程严格为：

1. 广播发现两块板，并按 UID/MAC 配置正式 IP；
2. 连接两块板并确认它们都是 slave；
3. 切换到 ``external`` 模式，等待两块板各自收到真实 XS20 SYNC；
4. 在两块板上配置 RFDC、上传同一条 CH1 高斯波形并 ARM；
5. 保持两块板处于 PREPARED，等待外部设备从 XS19 输入 Trigger；
6. 两块板都收到 Trigger 后打印计数和状态，直到用户 Ctrl-C 或超时。

本脚本不会调用 ``sync()``、``trigger()``、``emit_trigger()`` 或
``bypass_sync()``。因此它不能自行开始发波，必须由外部设备实际产生 SYNC
和 Trigger。脚本只验证数字状态；RF 输出幅度、频率、包络延迟和相位仍需用
示波器/频谱仪确认。

运行：

    PYTHONPATH=software python -m dr47.examples.hardware_dual_slave_external_trigger_test

使用前请修改本文件顶部的 ``SLAVE_A_DEVICE_UID`` / ``SLAVE_B_DEVICE_UID``（或
``SLAVE_A_MATCH_MAC`` / ``SLAVE_B_MATCH_MAC``）以及正式 IP。两块板角色相同，
不填写身份时驱动无法安全判断哪一块板对应哪一个目标 IP。
"""

from __future__ import annotations

import os
import time

import numpy as np

from ..capabilities import PlaybackState
from ..device import Dr47Device, rfdc_nco_plan_for_target
from ..errors import DriverError
from ..hardware_test_network import BoardNetworkAssignment, discover_and_provision_boards
from ..sequence import make_trigger_sequence
from ..waveforms import (
    iq_duration_to_interleaved_sample_count,
    make_iq_gaussian_sine_interleaved,
    place_interleaved_iq_in_record,
)


# ---------- 网络与板卡身份（按现场修改） ----------
BOARD_PORT = 1234
NETWORK_INTERFACE = os.environ.get("RFSOC_UDP_INTERFACE", "enp1s0f0")
DISCOVERY_SOURCE_IP = os.environ.get("RFSOC_DISCOVERY_SOURCE_IP", "169.254.250.11")
DISCOVERY_SOURCE_CIDR = os.environ.get(
    "RFSOC_DISCOVERY_SOURCE_CIDR", "169.254.250.11/16"
)
DISCOVERY_BROADCAST_IP = os.environ.get(
    "RFSOC_DISCOVERY_BROADCAST_IP", "169.254.255.255"
)
CONTROL_SOURCE_IP = os.environ.get("RFSOC_CONTROL_SOURCE_IP", DISCOVERY_SOURCE_IP)

# 两块板都是 slave，必须用 UID 或 MAC 区分；留空表示不按该字段筛选。
SLAVE_A_DEVICE_UID = ""
SLAVE_A_MATCH_MAC = ""
SLAVE_A_TARGET_IP = "169.254.100.101"
SLAVE_B_DEVICE_UID = ""
SLAVE_B_MATCH_MAC = ""
SLAVE_B_TARGET_IP = "169.254.100.102"
TARGET_SUBNET_MASK = "255.255.0.0"
TARGET_GATEWAY = "0.0.0.0"

# ---------- 波形与等待参数 ----------
CHANNEL_MASK = 0x01  # 只验证 CH1（逻辑通道 1 / vout00）
RF_TARGET_GHZ = 1.0
GAIN = 0.20
SAMPLE_RATE_HZ = 400_000_000.0
PULSE_DURATION_NS = 60.0
PULSE_DELAY_NS = 100.0
RECORD_DURATION_NS = 512.0
WAVEFORM_AMPLITUDE = 0.20
SYNC_TIMEOUT_S = 30.0
TRIGGER_TIMEOUT_S = 300.0


def _make_gaussian_record() -> np.ndarray:
    """生成 CH1 的 1 GHz（由 RFDC NCO 产生）60 ns 高斯包络记录。"""

    duration_s = PULSE_DURATION_NS * 1e-9
    active_count = iq_duration_to_interleaved_sample_count(duration_s, SAMPLE_RATE_HZ)
    active = make_iq_gaussian_sine_interleaved(
        frequency_hz=0.0,  # RF 载波由 RFDC NCO 设置，上传数据只放基带包络
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
    """创建绑定到指定 10G 网卡和源 IP 的设备对象。"""

    return Dr47Device(
        ip=ip,
        port=BOARD_PORT,
        udp_interface=NETWORK_INTERFACE,
        udp_source_ip=CONTROL_SOURCE_IP,
        timeout_s=1.0,
        retries=2,
        batch_mode=True,
    )


def _status(device: Dr47Device, label: str):
    """刷新并打印同步、Trigger、播放状态。"""

    status = device.status(refresh=True)
    caps = status.capabilities
    print(
        f"{label}: state={status.state.value}, role={caps.sync_role}, "
        f"mode={caps.sync_mode}, sync_seen={caps.sync_seen}, "
        f"sync_link_ready={caps.sync_link_ready}, "
        f"trigger_in/accepted={caps.trigger_input_count}/"
        f"{caps.trigger_accepted_count}"
    )
    return status


def _wait_rfdc_ready(device: Dr47Device, label: str) -> None:
    """等待启动阶段 RFDC、DAC MTS 和 NCO SYSREF 完成。"""

    deadline = time.monotonic() + SYNC_TIMEOUT_S
    last = None
    while time.monotonic() < deadline:
        last = device.status(refresh=True)
        caps = last.capabilities
        if caps.rfdc_ready and caps.dac_mts_ready and caps.nco_sync_ready:
            return
        if caps.dac_mts_failed:
            raise AssertionError(f"{label} DAC MTS 失败：error=0x{caps.dac_mts_error:04X}")
        time.sleep(0.1)
    raise AssertionError(f"{label} RFDC 未就绪：{last}")


def _wait_external_sync(device: Dr47Device, label: str) -> None:
    """只等待真实 XS20 事件，不使用 bypass 伪造同步。"""

    print(f"{label}：等待外部 XS20 SYNC（不会调用 bypass_sync）")
    deadline = time.monotonic() + SYNC_TIMEOUT_S
    while time.monotonic() < deadline:
        status = device.status(refresh=True)
        caps = status.capabilities
        if caps.sync_seen and caps.sync_link_ready:
            print(f"{label}：已收到 XS20 SYNC，Trigger 门控已打开")
            return
        if caps.sync_align_failed:
            raise AssertionError(f"{label} SYNC 对齐失败：error=0x{caps.sync_alignment_error:04X}")
        time.sleep(0.1)
    raise AssertionError(f"{label} 等待 XS20 SYNC 超时，请检查外部同步源和接线")


def _wait_prepared(device: Dr47Device, label: str) -> None:
    """等待 ARM 真正进入 PREPARED。"""

    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline:
        if device.status(refresh=True).state is PlaybackState.PREPARED:
            return
        time.sleep(0.05)
    raise AssertionError(f"{label} ARM 后没有进入 PREPARED")


def _wait_waveform_config(device: Dr47Device, label: str) -> None:
    """等待播放指令已经被 DDR executor 接收并预取。"""

    deadline = time.monotonic() + 15.0
    last = None
    while time.monotonic() < deadline:
        last = device.status(refresh=True)
        raw = last.capabilities.raw
        configured = int(raw.get("play_config_channel_mask", 0)) & CHANNEL_MASK
        if configured and raw.get("play_pending_valid") and raw.get("play_prefill_ready"):
            bad = int(raw.get("play_bad_instr_count", 0))
            if bad:
                raise AssertionError(f"{label} 播放指令被拒绝：bad_instr_count={bad}")
            return
        time.sleep(0.05)
    raise AssertionError(f"{label} 波形配置未就绪：{last}")


def _configure_upload_and_arm(device: Dr47Device, record: np.ndarray, label: str) -> None:
    """设置 NCO/增益，上传循环序列并 ARM，但绝不发送 Trigger。"""

    plan = rfdc_nco_plan_for_target(RF_TARGET_GHZ)
    device.set_xy_nco_frequency(1, plan["nco_ghz"])
    device.set_gain("xy", 1, GAIN, gain_type="norm")
    device.set_qc_on_off("xy", 1, "on")
    device.commit()
    sample_count = int(record.size // 2)
    device.upload_waveforms(
        {1: record},
        channel_sequences={1: make_trigger_sequence(sample_count)},
        wave_formats={1: "interleaved_iq"},
        auto_start=False,
        loop=True,
        channel_delays={1: 0},
        instruction_repeats=3,
    )
    _wait_waveform_config(device, label)
    device.arm(channel_mask=CHANNEL_MASK)
    _wait_prepared(device, label)
    print(f"{label}：波形已上传并 ARM，当前只等待外部 XS19 Trigger")


def _wait_external_triggers(devices: list[tuple[str, Dr47Device]], before: dict[str, int]) -> None:
    """等待两块板都至少接受一个 XS19 Trigger。"""

    print(
        f"两块从卡均已 PREPARED，等待外部 XS19 Trigger，最长 {TRIGGER_TIMEOUT_S:g} s。"
    )
    deadline = time.monotonic() + TRIGGER_TIMEOUT_S
    accepted: dict[str, bool] = {label: False for label, _ in devices}
    while time.monotonic() < deadline:
        for label, device in devices:
            status = _status(device, f"等待 {label} Trigger")
            if status.capabilities.trigger_accepted_count > before[label]:
                accepted[label] = True
        if all(accepted.values()):
            print("PASS：两块 slave 都已通过 XS19 接受外部 Trigger 并开始播放")
            return
        time.sleep(0.1)
    missing = ", ".join(label for label, done in accepted.items() if not done)
    raise AssertionError(f"等待外部 Trigger 超时，尚未触发：{missing}")


def run() -> int:
    """执行两块 slave 的 external SYNC + 外部 Trigger 流程。"""

    if not (SLAVE_A_DEVICE_UID or SLAVE_A_MATCH_MAC) or not (
        SLAVE_B_DEVICE_UID or SLAVE_B_MATCH_MAC
    ):
        print(
            "FAIL: 两块板都是 slave，无法仅按角色区分。请在脚本顶部填写 "
            "SLAVE_A/B_DEVICE_UID 或 SLAVE_A/B_MATCH_MAC。"
        )
        return 2

    devices: list[tuple[str, Dr47Device]] = []
    try:
        enrolled = discover_and_provision_boards(
            [
                BoardNetworkAssignment(
                    label="slave-A",
                    sync_role="slave",
                    ip=SLAVE_A_TARGET_IP,
                    device_uid=SLAVE_A_DEVICE_UID,
                    match_mac=SLAVE_A_MATCH_MAC,
                    subnet_mask=TARGET_SUBNET_MASK,
                    gateway=TARGET_GATEWAY,
                ),
                BoardNetworkAssignment(
                    label="slave-B",
                    sync_role="slave",
                    ip=SLAVE_B_TARGET_IP,
                    device_uid=SLAVE_B_DEVICE_UID,
                    match_mac=SLAVE_B_MATCH_MAC,
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
        record = _make_gaussian_record()
        for enrolled_board in enrolled:
            device = _new_device(enrolled_board.ip)
            devices.append((enrolled_board.label, device))
            print(f"连接 {enrolled_board.label}: {enrolled_board.ip} UID={enrolled_board.device_uid}")
            device.connect()
            status = _status(device, f"{enrolled_board.label} 初始状态")
            caps = status.capabilities
            if caps.sync_role != "slave":
                raise AssertionError(
                    f"{enrolled_board.label} 角色错误：期望 slave，实际 {caps.sync_role!r}"
                )
            if status.state is not PlaybackState.IDLE:
                print(f"{enrolled_board.label} 有残留播放，先 ABORT_MUTE")
                device.abort_mute()
            _wait_rfdc_ready(device, enrolled_board.label)
            # external 是默认模式，这里显式设置，防止复用过 bypass 的板卡状态。
            device.require_external_sync()

        # 两块板分别接收外部同步；任一块未同步都不会继续 ARM。
        for label, device in devices:
            _wait_external_sync(device, label)

        # 同步完成后再配置和 ARM；此处不产生任何本地 Trigger。
        for label, device in devices:
            _configure_upload_and_arm(device, record, label)
        before = {
            label: device.status(refresh=True).capabilities.trigger_accepted_count
            for label, device in devices
        }
        _wait_external_triggers(devices, before)
        print("提示：请用示波器确认两块板的 RF 输出、包络起点和相位关系")
        return 0
    except (DriverError, AssertionError, KeyboardInterrupt) as error:
        if isinstance(error, KeyboardInterrupt):
            print("收到 Ctrl-C，正在停止等待并清理播放状态")
        else:
            print(f"FAIL: {type(error).__name__}: {error}")
        return 2
    finally:
        for _label, device in reversed(devices):
            try:
                if device.connected:
                    device.abort_mute()
            except DriverError:
                pass
            device.close()


if __name__ == "__main__":
    raise SystemExit(run())

