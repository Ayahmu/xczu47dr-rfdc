"""主从板确定性同步（固定相位）的重复发波验收脚本。

背景与目标
----------
上一版同步逻辑的 SYNC 脉冲是在 ``pl_clk``（来自 PS PL_CLK0）异步时钟域里拉高的，
每次 ``sync()`` 到达两片 HMC7044 的相位是随机的，因此主从两路 RF 输出的相对相位
每次同步都会跳变，标定一次补偿无法长期复用。

本脚本配合已经改造的确定性 SYNC RTL 使用：SYNC 的上升沿被重定时到 HMC7044 回传
的 10 MHz monitor 时钟（``mclk_10m``），这个时钟与 HMC7044 的 VCXO/VCO 相位确定，
所以每次重新同步都会把 HMC7044 输出分频器 reseed 到相同的 VCO 相位。预期结果是：

* 每次上电/烧写后，主从两路 RF 输出的相位差是固定的；
* 只需要用示波器标定一次补偿，之后可以持续使用。

本脚本做的是**数字链路**的重复验证，不是 RF 相位的直接测量：

1. 连续执行多轮 ``SyncGroup.sync()``，确认每一轮主从的 ``sync_alignment_epoch``
   都稳定递增，且 DAC MTS / NCO SYSREF 对齐都完成；
2. 每轮同步后都 ARM 并发送一次原子 Trigger，确认主从都进入 RUNNING；
3. 打印每轮主从 Trigger 计数，便于和示波器/ILA 波形对照。

真正的 RF 相位是否固定，必须由你在示波器上同时观察两块板卡的 CH1/vout00
（50Ω 端接）完成；数字状态通过不代表相位已经达到某个具体数值。

硬件接线（与 single_trigger 测试一致）
------------------------------------
* 082 烧写 ``custom_xczu47dr_master``，081 烧写 ``custom_xczu47dr_slave``；
* 两块板 XS17 接同一 10 MHz 参考时钟；
* 082 XS20 -> 081 XS20；082 XS18 -> 081 XS19；
* 服务器通过 ``enp1s0f0`` 接入交换机，两块板也已接入交换机。

运行
----
    PYTHONPATH=software python -m dr47.examples.hardware_master_slave_deterministic_sync_test

网络和波形参数都在本文件顶部以模块常量定义，不接受命令行参数。
"""

from __future__ import annotations

import time

import numpy as np

from ..capabilities import PlaybackState
from ..device import Dr47Device
from ..errors import DriverError
from ..sequence import make_trigger_sequence
from ..sync_group import SyncGroup
from ..waveforms import (
    iq_duration_to_interleaved_sample_count,
    make_iq_gaussian_sine_interleaved,
    place_interleaved_iq_in_record,
)


# ---- 网络配置 ---------------------------------------------------------------
# 两块板已经通过广播发现 + provision 配置到下面的正式 IP，因此这里直接直连，
# 不再重复做 NETWORK_APPLY（重复配置会被固件以 0x0006 拒绝）。
BOARD_PORT = 1234
NETWORK_INTERFACE = "enp1s0f0"
CONTROL_SOURCE_IP = "169.254.250.11"
MASTER_TARGET_IP = "169.254.100.101"  # 082 = master
SLAVE_TARGET_IP = "169.254.100.102"   # 081 = slave

# ---- 波形参数 ---------------------------------------------------------------
# 400 MS/s 复基带；RFDC NCO 产生 1 GHz 射频载波，软件记录使用 0 Hz 基带。
SAMPLE_RATE_HZ = 400_000_000.0
RF_NCO_GHZ = 1.0
BASEBAND_GHZ = 0.0
PULSE_DURATION_NS = 60.0       # 高斯脉冲包络时长
PULSE_DELAY_NS = 100.0         # 记录内前置延迟，便于示波器/ILA 定位波形起点
RECORD_DURATION_NS = 512.0     # 一条记录总时长
WAVEFORM_AMPLITUDE = 0.2
GAIN = 0.2
CHANNEL_MASK = 0x01            # CH1 -> vout00

# ---- 重复同步次数 ------------------------------------------------------------
# 多次同步 + 发波用于确认相位可重复；示波器端应对每轮观察到相同的相对相位。
SYNC_ROUNDS = 10
ROUND_ABORT_SETTLE_S = 0.2     # 每轮 abort 后等待 executor 彻底停止的时间


def _make_gaussian_record() -> np.ndarray:
    """生成带前置延迟的 1 GHz 高斯正弦 IQ 记录。"""

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
    """创建绑定到指定 10G 网口和控制源地址的板卡驱动对象。"""

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


def _wait_state(
    device: Dr47Device,
    expected: PlaybackState,
    label: str,
    timeout_s: float = 5.0,
) -> None:
    """轮询等待板卡上报目标播放状态，而不是只依赖固定延时。

    ARM 与 TRIGGER 都需要跨越 PL 的 DDR/DAC 两个时钟域，状态回读存在几毫秒
    量级的抖动；固定 ``sleep`` 既慢又不可靠。这里用 ``status(refresh=True)``
    反复刷新真实硬件状态，直到进入目标状态或超时。
    """

    deadline = time.monotonic() + timeout_s
    last = None
    while time.monotonic() < deadline:
        last = device.status(refresh=True).state
        if last is expected:
            return
        time.sleep(0.02)
    actual = "未知" if last is None else last.value
    raise AssertionError(f"{label} 未进入 {expected.value}：实际 {actual}")


def _wait_counter(
    device: Dr47Device,
    attr: str,
    before: int,
    label: str,
) -> None:
    """等待指定计数增加。

    ``RUNNING`` 播放状态对 60ns/512ns 这类短记录是瞬态的：主卡启动后几十到
    几百纳秒内就 ``frame_done`` 并回到 ``armed``，20ms 级的状态轮询会错过它。
    因此这里改用稳定的硬件计数（XS18 输出 / XS19 接受）来确认一次播放确实被
    触发，而不是依赖 ``playback_running``。
    """

    deadline = time.monotonic() + 3.0
    last = int(before)
    while time.monotonic() < deadline:
        caps = device.status(refresh=True).capabilities
        last = int(getattr(caps, attr))
        if last > before:
            print(f"{label}：{before} -> {last}")
            return
        time.sleep(0.01)
    raise AssertionError(f"{label} 计数未增加，仍为 {last}")


def _wait_waveform_config(device: Dr47Device, label: str) -> None:
    """等待 DDR executor 接收 PLAY/END 并完成波形预取。"""

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


def _snapshot(device: Dr47Device, label: str) -> str:
    """刷新并格式化一块板卡的同步与播放状态。"""

    caps = device.status(refresh=True).capabilities
    return (
        f"{label}: state={caps.playback_state.value}, "
        f"align_epoch={caps.sync_alignment_epoch}, "
        f"sync_seen={caps.sync_seen}, link={caps.sync_link_ready}, "
        f"mts_ready={caps.dac_mts_ready}, nco_ready={caps.nco_sync_ready}, "
        f"trigger_out={caps.trigger_output_count}, "
        f"trigger_in={caps.trigger_input_count}, "
        f"trigger_acc={caps.trigger_accepted_count}"
    )


def run() -> int:
    """连续多轮执行 sync -> ARM -> trigger -> abort，验证同步可重复。"""

    record = _make_gaussian_record()
    master = _new_device(MASTER_TARGET_IP)
    slave = _new_device(SLAVE_TARGET_IP)
    try:
        master.connect()
        slave.connect()

        # 清理上次测试残留，避免 SET_SYNC_ROLE 被 0x0003 拒绝。
        for device in (master, slave):
            try:
                device.abort_mute()
            except DriverError:
                pass
        time.sleep(0.5)

        # 两块板都使用严格 external 模式；从卡不会伪造 sync_seen。
        master.require_external_sync()
        slave.require_external_sync()
        _wait_rfdc_ready(master, "082 主卡")
        _wait_rfdc_ready(slave, "081 从卡")

        print(f"开始连续 {SYNC_ROUNDS} 轮同步发波验证（每轮重新上传波形）")

        group = SyncGroup(master, slave, timeout_s=15.0, poll_interval_s=0.01)
        prev_master_epoch = master.status(refresh=True).capabilities.sync_alignment_epoch
        prev_slave_epoch = slave.status(refresh=True).capabilities.sync_alignment_epoch

        for round_no in range(1, SYNC_ROUNDS + 1):
            # 第 1 步：发出 XS20 SYNC；固件等待 5 秒后重新完成 DAC MTS / NCO 对齐。
            # 这里使用默认的 abort_before_sync=True：它会先停止上一轮播放，并
            # 清空波形 executor 配置，因此本步骤之后必须重新上传波形。
            alignment = group.sync(epoch=1, abort_before_sync=True)
            print(
                f"[{round_no}/{SYNC_ROUNDS}] SYNC 完成："
                f"master_epoch={alignment.master_alignment_epoch}, "
                f"slave_epoch={alignment.slave_alignment_epoch}, "
                f"elapsed={alignment.elapsed_s:.3f}s"
            )
            if alignment.master_alignment_epoch == prev_master_epoch:
                raise AssertionError("主卡 alignment epoch 没有递增")
            if alignment.slave_alignment_epoch == prev_slave_epoch:
                raise AssertionError("从卡 alignment epoch 没有递增")
            prev_master_epoch = alignment.master_alignment_epoch
            prev_slave_epoch = alignment.slave_alignment_epoch

            # 第 2 步：重新上传波形。上一步的 abort_mute 已清空 executor 的
            # PLAY/END 配置，因此每一轮都必须重新配置并等待 DDR 预取完成。
            _configure_and_upload(master, record, "082 主卡")
            _configure_and_upload(slave, record, "081 从卡")

            # 第 3 步：同步后 ARM；等待两块板都进入 PREPARED。
            master.arm(channel_mask=CHANNEL_MASK)
            slave.arm(channel_mask=CHANNEL_MASK)
            _wait_state(master, PlaybackState.PREPARED, "082 主卡")
            _wait_state(slave, PlaybackState.PREPARED, "081 从卡")

            # 第 4 步：主卡只发一次原子 Trigger，同时启动本地播放和 XS18 输出。
            # 触发前先记录计数，随后用计数验证两条硬件路径，而不是轮询瞬态的
            # RUNNING 状态（短波形几十到几百纳秒就会播放完并回到 armed）。
            master_before = master.status(refresh=True).capabilities
            slave_before = slave.status(refresh=True).capabilities
            master.trigger()
            _wait_counter(
                master,
                "trigger_output_count",
                master_before.trigger_output_count,
                "082 XS18 输出",
            )
            _wait_counter(
                slave,
                "trigger_accepted_count",
                slave_before.trigger_accepted_count,
                "081 XS19 接受",
            )
            master_caps = master.status(refresh=True).capabilities
            slave_caps = slave.status(refresh=True).capabilities
            print(f"  {_snapshot(master, '主卡')}")
            print(f"  {_snapshot(slave, '从卡')}")

            # 第 5 步：停止本轮播放，为下一轮同步留出干净的 IDLE 状态。
            master.abort_mute()
            slave.abort_mute()
            time.sleep(ROUND_ABORT_SETTLE_S)

        print(
            f"PASS: 连续 {SYNC_ROUNDS} 轮 sync() 均完成 MTS/NCO 重对齐并触发主从播放。"
        )
        print("请用示波器同时观察 CH1/vout00，确认每轮相对相位是否一致；")
        print("若一致，标定一次补偿即可持续使用。")
        return 0
    except (DriverError, AssertionError) as error:
        print(f"FAIL: {type(error).__name__}: {error}")
        return 2
    finally:
        for device in (slave, master):
            try:
                if device.connected:
                    device.abort_mute()
            except DriverError:
                pass
            device.close()


if __name__ == "__main__":
    raise SystemExit(run())
