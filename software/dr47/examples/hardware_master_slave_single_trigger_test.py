"""082 主卡单次触发 / 081 从卡同步发波的最简测试（只发一次 trigger）。

和持续触发脚本的唯一区别：这里只调用一次 ``master.trigger()``，随后把两块板
保持在 RUNNING 状态，便于在示波器上观察两路的 1 GHz 高斯正弦波形。

loop 波形一次 trigger 之后会由 FPGA 自行循环播放，不再需要上位机参与，所以
脚本触发并确认状态后直接退出，**不发送 ABORT_MUTE**，板卡会一直播下去。停止
播放请另行调用 ``device.abort_mute()``，或运行任一带 abort 清理的脚本。

运行：

    PYTHONPATH=software python -m dr47.examples.hardware_master_slave_single_trigger_test
"""

from __future__ import annotations

import time

import numpy as np

from ..capabilities import PlaybackState
from ..device import Dr47Device
from ..errors import DeviceStatusError, DriverError
from ..sequence import make_trigger_sequence
from ..sync_group import SyncGroup
from ..waveforms import (
    iq_duration_to_interleaved_sample_count,
    make_iq_gaussian_sine_interleaved,
    place_interleaved_iq_in_record,
)


BOARD_PORT = 1234
NETWORK_INTERFACE = "enp1s0f0"
CONTROL_SOURCE_IP = "169.254.250.11"

MASTER_TARGET_IP = "169.254.100.101"
SLAVE_TARGET_IP = "169.254.100.102"

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
    """生成带前置延迟的 1 GHz 高斯正弦 IQ 记录。

    上传数据是 I0,Q0,I1,Q1,... 的 int16 复基带。RFDC NCO 负责产生 1 GHz
    射频载波，软件记录使用 0 Hz 基带高斯包络；记录开头预留 100 ns 的零值
    延迟，方便示波器/ILA 定位波形起点。
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
    while time.monotonic() < deadline:
        caps = device.status(refresh=True).capabilities
        if caps.rfdc_ready and caps.dac_mts_ready and caps.nco_sync_ready:
            return
        if caps.dac_mts_failed:
            raise AssertionError(f"{label} DAC MTS 失败：error=0x{caps.dac_mts_error:04X}")
        time.sleep(0.05)
    raise AssertionError(f"{label} RFDC 未就绪")


def _wait_prepared(device: Dr47Device, label: str) -> None:
    """等待板卡进入 PREPARED，而不是只相信 ARM 命令 ACK。"""

    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        if device.status(refresh=True).state is PlaybackState.PREPARED:
            return
        time.sleep(0.02)
    raise AssertionError(f"{label} ARM 未进入 PREPARED")


def _wait_waveform_config(device: Dr47Device, label: str) -> None:
    """等待 DDR 执行器接收 PLAY/END 并完成波形预取。"""

    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline:
        raw = device.status(refresh=True).capabilities.raw
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
        f"running={caps.playback_running}, "
        f"trigger_acc={caps.trigger_accepted_count}, "
        f"sync_link_ready={caps.sync_link_ready}"
    )


def run() -> int:
    """执行主卡单次触发、从卡同步发波的最简验收流程。"""

    record = _make_gaussian_record()
    master = _new_device(MASTER_TARGET_IP)
    slave = _new_device(SLAVE_TARGET_IP)
    master.connect()
    slave.connect()

    # 清掉上一次测试残留状态，避免 SET_SYNC_ROLE 被 0x0003 拒绝。
    for device in (master, slave):
        try:
            device.abort_mute()
        except DriverError:
            pass
    # abort 脉冲要穿过 DDR executor 彻底停下 loop，再进入后续配置。
    time.sleep(0.5)
    master.require_external_sync()
    slave.require_external_sync()
    _wait_rfdc_ready(master, "082 主卡")
    _wait_rfdc_ready(slave, "081 从卡")
    _configure_and_upload(master, record, "082 主卡")
    _configure_and_upload(slave, record, "081 从卡")

    alignment = SyncGroup(master, slave, timeout_s=5.0, poll_interval_s=0.01).sync(
        epoch=1, abort_before_sync=False
    )
    print(
        f"SYNC 完成：master_epoch={alignment.master_alignment_epoch}，"
        f"slave_epoch={alignment.slave_alignment_epoch}"
    )
    master.arm(channel_mask=CHANNEL_MASK)
    slave.arm(channel_mask=CHANNEL_MASK)
    _wait_prepared(master, "082 主卡")
    _wait_prepared(slave, "081 从卡")
    # prepared 是从 DAC 域同步回 DDR 域的，留一点稳定时间再触发。
    time.sleep(0.3)
    print("两块板卡均已 ARM / PREPARED")

    # 只发一次 trigger。
    mc = master.status(refresh=True).capabilities
    sc = slave.status(refresh=True).capabilities
    print(
        f"触发前状态：主卡 prepared={mc.playback_prepared} running={mc.playback_running} "
        f"link={mc.sync_link_ready}；从卡 prepared={sc.playback_prepared} "
        f"running={sc.playback_running} link={sc.sync_link_ready}"
    )
    for attempt in range(3):
        try:
            master.trigger()
            break
        except DeviceStatusError:
            if attempt == 2:
                raise
            time.sleep(0.2)
    print("已发出一次 master.trigger()")
    time.sleep(0.5)
    print(_snapshot(master, "主卡"))
    print(_snapshot(slave, "从卡"))

    master_caps = master.status(refresh=True).capabilities
    slave_caps = slave.status(refresh=True).capabilities
    if master_caps.playback_running and slave_caps.playback_running:
        print("PASS：主从两路均已进入 RUNNING 并在 FPGA 内循环播放")
        print("请用示波器同时观察两块板卡的 CH1/vout00（50Ω 端接）")
    else:
        print("WARN：并非两路都处于 RUNNING，请查看上方状态")

    # 不发送 ABORT_MUTE，板卡继续循环播放供示波器观察。
    print("板卡保持播放中。停止请调用 device.abort_mute()。")
    master.close()
    slave.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
