#!/usr/bin/env python3
"""从卡跳过 SYNC、等待 XS19 外部 Trigger 的双通道测试。

运行前连接：

    XS17 <- 250 MHz 参考时钟
    外部 Trigger 源 -> XS19
    XS20 保持断开
    CH1、CH2 -> 示波器或 50 ohm 负载

脚本将从卡设置为 ``bypass`` 模式，使 XS20 未收到 SYNC 时也允许 XS19 Trigger。
每个被接受的外部 Trigger 会同时启动 CH1 和 CH2，并播放一组高斯脉冲。脚本只
观察 XS19 的硬件计数，不会调用软件 ``trigger()``，也不会从 XS18 输出 Trigger。

本脚本没有命令行参数，也不读取环境变量。需要改变网络、波形或测试参数时，
直接修改下方“用户配置”区域，然后直接运行本文件。
"""

from __future__ import annotations

import math
import time

import numpy as np

from dr47 import BurstSchedule, Dr47Device, PlaybackState
from dr47.errors import DriverError


# =============================================================================
# 用户配置：所有需要调整的参数都直接写在这里
# =============================================================================

# 板卡和主机 10G 网口
BOARD_IP = "169.254.149.60"
BOARD_PORT = 1234
UDP_INTERFACE = "enp1s0f0"
UDP_SOURCE_IP = "169.254.250.11"

# DAC 输出配置
OUTPUT_CHANNELS = (1, 2)
RF_FREQUENCY_GHZ = 4.9385
OUTPUT_GAIN = 1.0

# 单个高斯脉冲。上传数据是 400 MS/s 复数 IQ 基带，射频载波由 RFDC NCO 产生。
SAMPLE_RATE_HZ = 400_000_000.0
GAUSSIAN_DURATION_NS = 30.0
GAUSSIAN_FWHM_NS = 15.0
GAUSSIAN_AMPLITUDE = 0.7

# 每个外部 Trigger 播放一组脉冲：
#   FIRST_DELAY_NS：Trigger 到第一个脉冲的延迟
#   PULSE_INTERVAL_NS：相邻脉冲起点之间的时间
#   PULSES_PER_TRIGGER：一组内的脉冲数量
# 调度时间由硬件向上量化到 20 ns。
FIRST_DELAY_NS = 20.0
PULSE_INTERVAL_NS = 1000.0
PULSES_PER_TRIGGER = 10

# 收到并接受指定数量的外部 Trigger 后结束测试。
TRIGGER_COUNT = 10000

# 网络超时和状态轮询周期
UDP_TIMEOUT_S = 2.0
UDP_RETRIES = 3
RFDC_READY_TIMEOUT_S = 30.0
PLAYBACK_READY_TIMEOUT_S = 10.0
POLL_INTERVAL_S = 0.02


COUNTER_MASK = 0xFFFF_FFFF
CHANNEL_MASK = sum(1 << (channel - 1) for channel in OUTPUT_CHANNELS)


def make_gaussian_waveform() -> np.ndarray:
    """生成小端 int16 交错 IQ 波形，内存排列为 I0,Q0,I1,Q1,...。"""

    # 向上取整复数样点数，保证实际波形不会短于配置的持续时间。
    sample_count = math.ceil(GAUSSIAN_DURATION_NS * 1e-9 * SAMPLE_RATE_HZ)
    time_ns = np.arange(sample_count, dtype=np.float64) / SAMPLE_RATE_HZ * 1e9

    # FWHM = 2 * sqrt(2 * ln(2)) * sigma。
    center_ns = (sample_count - 1) / SAMPLE_RATE_HZ * 0.5e9
    sigma_ns = GAUSSIAN_FWHM_NS / (2.0 * math.sqrt(2.0 * math.log(2.0)))
    envelope = np.exp(-0.5 * ((time_ns - center_ns) / sigma_ns) ** 2)
    envelope *= GAUSSIAN_AMPLITUDE * 32767.0

    # 复基带频率为 0 Hz，所以 Q 全为 0；最终 RF 频率在配置 RFDC 时设置。
    waveform = np.zeros(sample_count * 2, dtype="<i2")
    waveform[0::2] = np.rint(envelope).astype("<i2")
    return waveform


def counter_delta(current: int, previous: int) -> int:
    """计算 32 位硬件计数器增量，并兼容一次自然回绕。"""

    return (int(current) - int(previous)) & COUNTER_MASK


def print_status(device: Dr47Device, label: str) -> None:
    """打印本测试最关心的状态，避免输出完整协议字典。"""

    status = device.status(refresh=True)
    caps = status.capabilities
    print(
        f"    {label}: state={status.state.value}, "
        f"sync={caps.sync_role}/{caps.sync_mode}, "
        f"trigger(in/accepted/out)="
        f"{caps.trigger_input_count}/{caps.trigger_accepted_count}/"
        f"{caps.trigger_output_count}"
    )


def wait_rfdc_ready(device: Dr47Device) -> None:
    """等待 RFDC、DAC MTS 和 NCO 同步全部就绪。"""

    deadline = time.monotonic() + RFDC_READY_TIMEOUT_S
    while time.monotonic() < deadline:
        caps = device.status(refresh=True).capabilities
        if caps.dac_mts_failed:
            raise RuntimeError(f"DAC MTS 失败，错误码 0x{caps.dac_mts_error:04X}")
        if caps.rfdc_ready and caps.dac_mts_ready and caps.nco_sync_ready:
            return
        time.sleep(POLL_INTERVAL_S)
    raise TimeoutError("等待 RFDC、DAC MTS 和 NCO 就绪超时")


def wait_playback_ready(device: Dr47Device, label: str) -> None:
    """等待播放器进入 PREPARED，确认可以安全接收下一个 Trigger。"""

    burst_ns = (
        FIRST_DELAY_NS
        + (PULSES_PER_TRIGGER - 1) * PULSE_INTERVAL_NS
        + GAUSSIAN_DURATION_NS
    )
    timeout_s = max(PLAYBACK_READY_TIMEOUT_S, burst_ns * 1e-9 + 1.0)
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if device.status(refresh=True).state is PlaybackState.PREPARED:
            return
        time.sleep(POLL_INTERVAL_S)
    raise TimeoutError(f"{label}：播放器未进入 prepared 状态")


def wait_external_triggers(device: Dr47Device, input_before: int, accepted_before: int) -> None:
    """持续等待 XS19 外部 Trigger，直到接受计数达到目标。"""

    last_input = -1
    last_accepted = -1
    print(f"    已 ARM，等待 {TRIGGER_COUNT} 次 XS19 外部 Trigger...")

    while True:
        caps = device.status(refresh=True).capabilities
        input_count = counter_delta(caps.trigger_input_count, input_before)
        accepted_count = counter_delta(caps.trigger_accepted_count, accepted_before)

        if input_count != last_input or accepted_count != last_accepted:
            print(
                f"    XS19: 输入={input_count}, 接受={accepted_count}, "
                f"目标={TRIGGER_COUNT}",
                flush=True,
            )
            last_input = input_count
            last_accepted = accepted_count

        if input_count > accepted_count:
            raise RuntimeError(
                "存在未被播放器接受的 XS19 Trigger；请降低外部 Trigger 频率，"
                "并确保两次 Trigger 之间播放器已经回到 prepared"
            )
        if accepted_count > TRIGGER_COUNT:
            raise RuntimeError(
                f"接受计数超过目标（{accepted_count} > {TRIGGER_COUNT}）；"
                "请在脚本提示 ARM 后再启动外部 Trigger 源"
            )
        if accepted_count == TRIGGER_COUNT:
            wait_playback_ready(device, "最后一组波形播放完成后")
            return

        time.sleep(POLL_INTERVAL_S)


def validate_config() -> None:
    """访问硬件前检查常见的参数错误。"""

    if not OUTPUT_CHANNELS or any(
        channel not in range(1, 9) for channel in OUTPUT_CHANNELS
    ):
        raise ValueError("OUTPUT_CHANNELS 只能包含 CH1..CH8")
    if not 0.0 <= RF_FREQUENCY_GHZ <= 6.4:
        raise ValueError("RF_FREQUENCY_GHZ 必须在 0..6.4 GHz 范围内")
    if not 0.0 < OUTPUT_GAIN <= 1.0:
        raise ValueError("OUTPUT_GAIN 必须在 (0, 1] 范围内")
    if not 0.0 < GAUSSIAN_AMPLITUDE <= 1.0:
        raise ValueError("GAUSSIAN_AMPLITUDE 必须在 (0, 1] 范围内")
    if GAUSSIAN_DURATION_NS <= 0.0 or GAUSSIAN_FWHM_NS <= 0.0:
        raise ValueError("高斯脉冲持续时间和 FWHM 必须为正数")
    if FIRST_DELAY_NS < 0.0 or PULSE_INTERVAL_NS <= 0.0:
        raise ValueError("首次延迟不能为负，脉冲间隔必须为正数")
    if PULSES_PER_TRIGGER <= 0 or TRIGGER_COUNT <= 0:
        raise ValueError("脉冲数量和 Trigger 数量必须为正整数")
    if POLL_INTERVAL_S <= 0.0:
        raise ValueError("POLL_INTERVAL_S 必须为正数")


def run_test() -> None:
    """完成连接、bypass、配置、ARM、等待外部 Trigger 和计数核对。"""

    validate_config()
    waveform = make_gaussian_waveform()
    schedule = BurstSchedule(
        first_delay_ns=FIRST_DELAY_NS,
        interval_ns=PULSE_INTERVAL_NS,
        repetitions=PULSES_PER_TRIGGER,
        debug_alternate=False,
    )
    device = Dr47Device(
        ip=BOARD_IP,
        port=BOARD_PORT,
        udp_interface=UDP_INTERFACE,
        udp_source_ip=UDP_SOURCE_IP,
        timeout_s=UDP_TIMEOUT_S,
        retries=UDP_RETRIES,
        batch_mode=True,
        sync_role="slave",
    )

    try:
        print(f"[1/5] 连接板卡 {BOARD_IP}:{BOARD_PORT}")
        device.connect()
        device.abort_playback()  # 清理上次中断可能留下的 ARM/RUNNING 状态。

        caps = device.status(refresh=True).capabilities
        if caps.sync_role != "slave":
            raise RuntimeError(f"需要 slave bitstream，当前角色是 {caps.sync_role!r}")
        wait_rfdc_ready(device)
        print_status(device, "板卡就绪")

        print("[2/5] 启用 bypass，跳过 XS20 SYNC 门控")
        device.bypass_sync()
        caps = device.status(refresh=True).capabilities
        if caps.sync_mode != "bypass" or not caps.sync_link_ready:
            raise RuntimeError("bypass 未生效，XS19 Trigger 门控仍未打开")

        print(f"[3/5] 配置 CH1/CH2，目标射频 {RF_FREQUENCY_GHZ:g} GHz")
        for channel in OUTPUT_CHANNELS:
            device.set_xy_target_frequency(channel, RF_FREQUENCY_GHZ)
            device.set_gain("xy", channel, OUTPUT_GAIN, gain_type="norm")
            device.set_qc_on_off("xy", channel, "on")
        device.commit()

        print("[4/5] 上传高斯波形并 ARM")
        playback = device.configure_playback(
            {channel: waveform for channel in OUTPUT_CHANNELS},
            schedule=schedule,
            wave_formats={channel: "interleaved_iq" for channel in OUTPUT_CHANNELS},
            channel_mask=CHANNEL_MASK,
            bulk_upload=True,
        )
        device.arm_playback(channel_mask=CHANNEL_MASK)
        wait_playback_ready(device, "ARM 后")
        print(
            "    实际调度: "
            f"首次延迟={playback.schedule.effective_first_delay_ns:g} ns, "
            f"间隔={playback.schedule.effective_interval_ns:g} ns, "
            f"每次 Trigger={playback.schedule.repetitions} 个脉冲"
        )

        baseline = device.status(refresh=True).capabilities
        print("[5/5] 等待并核对外部 Trigger")
        wait_external_triggers(
            device,
            input_before=baseline.trigger_input_count,
            accepted_before=baseline.trigger_accepted_count,
        )

        final = device.status(refresh=True).capabilities
        input_count = counter_delta(
            final.trigger_input_count, baseline.trigger_input_count
        )
        accepted_count = counter_delta(
            final.trigger_accepted_count, baseline.trigger_accepted_count
        )
        output_count = counter_delta(
            final.trigger_output_count, baseline.trigger_output_count
        )
        print(
            f"    本轮计数: XS19 输入={input_count}, XS19 接受={accepted_count}, "
            f"XS18 输出={output_count}"
        )
        if input_count != TRIGGER_COUNT or accepted_count != TRIGGER_COUNT:
            raise RuntimeError("XS19 输入或接受计数与目标不一致")
        if output_count != 0:
            raise RuntimeError("本测试不应输出 XS18 Trigger，但输出计数发生了变化")
        print("PASS: 已跳过 SYNC，并由 XS19 外部 Trigger 完成 CH1/CH2 播放")
    finally:
        # 成功、失败或 Ctrl-C 中断后都尽力停止并静音，便于安全地再次运行。
        if device.connected:
            try:
                device.abort_playback()
            except DriverError as error:
                print(f"WARN: 清理板卡失败：{error}")
        device.close()


def main() -> int:
    try:
        run_test()
        return 0
    except KeyboardInterrupt:
        print("\nSTOP: 用户中断，板卡已停止并静音")
        return 130
    except (DriverError, RuntimeError, TimeoutError, ValueError) as error:
        print(f"FAIL: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
