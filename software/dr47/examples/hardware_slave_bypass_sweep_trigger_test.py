"""从卡 bypass + XS19 外部 Trigger 的分组扫频示例。

本脚本适用于没有 XS20 SYNC 源、但需要由外部设备从 XS19 触发播放的
slave bitstream。脚本只在启动时调用一次 ``bypass_sync()``；每个频点把同一条
有限高斯记录上传到 CH1 和 CH2，并由同一个 XS19 Trigger 同时启动两个通道。
收到 ``TRIGGERS_PER_FREQUENCY`` 个外部 Trigger 后，停止当前播放、切换 RFDC
目标频率并重新 ARM，然后继续等待下一组 Trigger。

频率、步进和每个频点的 Trigger 数量都在本文件顶部修改，不使用命令行参数。
``SWEEP_POINTS = None`` 表示持续扫频直到 Ctrl-C；设置为正整数可运行有限个
频点。外部 Trigger 源必须在每次切频期间暂停，等脚本重新打印 ``PREPARED``；
RFDC_APPLY 要求播放器处于 disarmed/idle，暂停期间到达的脉冲无法排队。

计数以 XS19 的 ``trigger_input_count`` 为准，并要求同一组的
``trigger_accepted_count`` 增量相同。这样可以保证“100 次外部输入”确实对应
100 次播放；如果 Trigger 过快导致丢失或主机轮询跨过了分组边界，脚本会失败并
报告原因，而不会悄悄把一个频点的脉冲算到下一个频点。
"""

from __future__ import annotations

import math
import time

from ..capabilities import PlaybackState
from ..device import rfdc_nco_plan_for_target
from ..errors import DriverError
from ..hardware_test_network import BoardNetworkAssignment
from . import _common as common


EXPECTED_SYNC_ROLE = "slave"
BOARD_DEVICE_UID = common.SLAVE_DEVICE_UID
BOARD_MATCH_MAC = common.SLAVE_MATCH_MAC
BOARD_TARGET_IP = common.SLAVE_TARGET_IP
BOARD_TARGET_MAC = common.SLAVE_TARGET_MAC

# ---------------------------- 用户扫频配置 ----------------------------
SWEEP_ENABLED = True
START_FREQUENCY_GHZ = 4.000
FREQUENCY_STEP_GHZ = 0.001
TRIGGERS_PER_FREQUENCY = 10000
# None: 4.000, 4.001, ... 持续运行；例如 11 表示运行到 4.010 GHz 后退出。
SWEEP_POINTS: int | None = None
# SWEEP_ENABLED=False 时只运行 START_FREQUENCY_GHZ 这一组，然后正常退出。

# 外部触发等待不设置超时；重新 ARM/切频的单步操作仍然有有限超时。
TRIGGER_POLL_INTERVAL_S = common.POLL_INTERVAL_S
REARM_TIMEOUT_S = 10.0

_COUNTER_MASK = 0xFFFFFFFF


def _counter_delta(current: int, before: int) -> int:
    """Return a 32-bit hardware counter delta, including one wraparound."""

    return (int(current) - int(before)) & _COUNTER_MASK


def _frequency_for_point(point_index: int) -> float:
    """Return the target RF frequency for a zero-based sweep point."""

    step_index = int(point_index) if SWEEP_ENABLED else 0
    # Round away binary floating-point residue before converting to the
    # integer-Hz RFCTRL2 field (1 MHz steps should remain exactly representable
    # at the public API boundary).
    return round(
        float(START_FREQUENCY_GHZ) + step_index * float(FREQUENCY_STEP_GHZ),
        12,
    )


def _has_next_point(point_index: int) -> bool:
    return bool(SWEEP_ENABLED) and (
        SWEEP_POINTS is None or int(point_index) + 1 < int(SWEEP_POINTS)
    )


def _validate_sweep_config() -> None:
    if not isinstance(SWEEP_ENABLED, bool):
        raise ValueError("SWEEP_ENABLED must be bool")
    if not math.isfinite(float(START_FREQUENCY_GHZ)):
        raise ValueError("START_FREQUENCY_GHZ must be finite")
    if not math.isfinite(float(FREQUENCY_STEP_GHZ)):
        raise ValueError("FREQUENCY_STEP_GHZ must be finite")
    if int(TRIGGERS_PER_FREQUENCY) <= 0:
        raise ValueError("TRIGGERS_PER_FREQUENCY must be positive")
    if SWEEP_POINTS is not None and int(SWEEP_POINTS) <= 0:
        raise ValueError("SWEEP_POINTS must be None or positive")
    # Validate the first point, and the final configured point when it is finite.
    # This gives a configuration error before a board is touched instead of
    # failing halfway through a long sweep.
    if SWEEP_POINTS is not None:
        last_frequency = _frequency_for_point(int(SWEEP_POINTS) - 1)
        if not math.isfinite(last_frequency):
            raise ValueError("the last sweep frequency must be finite")
    first_frequency = _frequency_for_point(0)
    if not math.isfinite(first_frequency):
        raise ValueError("the first sweep frequency must be finite")
    rfdc_nco_plan_for_target(first_frequency)
    if SWEEP_ENABLED and SWEEP_POINTS is not None:
        rfdc_nco_plan_for_target(last_frequency)


def _wait_external_trigger_group(
    device,
    *,
    frequency_ghz: float,
    before_input: int,
    before_accepted: int,
) -> tuple[int, int]:
    """Wait for one exact input/accepted Trigger group.

    The external source should be slower than the status polling interval and
    must be paused while retuning.  If a status response observes more than the
    configured group size, the host cannot identify the frequency boundary, so
    fail instead of silently assigning an event to the wrong point.
    """

    target = int(TRIGGERS_PER_FREQUENCY)
    last_reported = -1
    print(
        f"[{frequency_ghz:.6f} GHz] 等待 {target} 次 XS19 Trigger "
        "(外部源请在切频时暂停)"
    )
    while True:
        caps = device.status(refresh=True).capabilities
        input_delta = _counter_delta(caps.trigger_input_count, before_input)
        accepted_delta = _counter_delta(caps.trigger_accepted_count, before_accepted)

        # A jump over the boundary means that multiple external edges arrived
        # between two status polls.  No software-side counter can recover the
        # exact edge at which the old frequency should have stopped.
        if input_delta > target:
            raise RuntimeError(
                f"{frequency_ghz:.6f} GHz 组收到 {input_delta} 次 Trigger，"
                f"超过目标 {target}；请降低 Trigger 频率或缩短轮询间隔"
            )
        if accepted_delta > target:
            raise RuntimeError(
                f"{frequency_ghz:.6f} GHz 组接受计数跳到 {accepted_delta}，"
                f"超过目标 {target}；无法确定切频边界"
            )

        if input_delta != last_reported and (
            input_delta == target or input_delta == 1 or input_delta % 10 == 0
        ):
            print(
                f"[{frequency_ghz:.6f} GHz] Trigger 输入/接受 "
                f"{input_delta}/{accepted_delta}/{target}"
            )
            last_reported = input_delta

        if input_delta == target:
            if accepted_delta != target:
                raise RuntimeError(
                    f"{frequency_ghz:.6f} GHz 组输入 {target} 次，但只接受 "
                    f"{accepted_delta} 次；请放慢外部 Trigger，避免 PREPARED 窗口丢脉冲"
                )
            return input_delta, accepted_delta
        time.sleep(TRIGGER_POLL_INTERVAL_S)


def _configure_frequency_and_arm(device, frequency_ghz: float, point_index: int) -> None:
    """Apply one target RF frequency and prepare a finite two-channel record."""

    record = common.make_gaussian_record(rf_nco_frequency_ghz=frequency_ghz)
    common.configure_and_arm(
        device,
        record,
        label=f"从卡频点 {point_index + 1}",
        rf_nco_frequency_ghz=frequency_ghz,
        channels=(1, 2),
    )


def run() -> int:
    """Discover the slave, bypass XS20, then run the configured external sweep."""

    device = None
    try:
        _validate_sweep_config()
        enrolled = common.enroll(
            [
                BoardNetworkAssignment(
                    label="从卡",
                    sync_role=EXPECTED_SYNC_ROLE,
                    ip=BOARD_TARGET_IP,
                    device_uid=BOARD_DEVICE_UID,
                    mac=BOARD_TARGET_MAC,
                    match_mac=BOARD_MATCH_MAC,
                    subnet_mask=common.TARGET_SUBNET_MASK,
                    gateway=common.TARGET_GATEWAY,
                )
            ]
        )[EXPECTED_SYNC_ROLE]
        device = common.new_device(enrolled)
        initial = common.show_status(device, "从卡初始")
        if initial.capabilities.sync_role != EXPECTED_SYNC_ROLE:
            raise AssertionError(
                f"需要 slave bitstream，实际为 {initial.capabilities.sync_role!r}"
            )
        common.wait_rfdc_ready(device, "从卡")
        common.ensure_idle(device, "从卡")

        # bypass 只放开本地 Trigger 门控，不伪造 sync_seen，也不发送 XS20。
        device.bypass_sync()
        bypass = common.show_status(device, "bypass_sync() 后")
        if bypass.capabilities.sync_mode != "bypass":
            raise AssertionError("bypass_sync() 后同步模式不是 bypass")
        if bypass.capabilities.sync_seen:
            raise AssertionError("bypass 不得伪造 sync_seen=True")
        if not bypass.capabilities.sync_link_ready:
            raise AssertionError("bypass 后 XS19 Trigger 门控未打开")

        point_index = 0
        frequency_ghz = _frequency_for_point(point_index)
        _configure_frequency_and_arm(device, frequency_ghz, point_index)

        while True:
            # Baselines are taken only after PREPARED.  The external source must
            # therefore remain quiet until this point is printed by the helper.
            prepared = device.status(refresh=True).capabilities
            _wait_external_trigger_group(
                device,
                frequency_ghz=frequency_ghz,
                before_input=prepared.trigger_input_count,
                before_accepted=prepared.trigger_accepted_count,
            )
            # The accepted counter advances at launch time.  Wait for the
            # finite record to finish before ABORT_MUTE, otherwise a short
            # record could be truncated while changing frequency.
            common.wait_state(
                device,
                PlaybackState.PREPARED,
                f"{frequency_ghz:.6f} GHz 最后一条波形完成",
                REARM_TIMEOUT_S,
            )
            print(
                f"[{frequency_ghz:.6f} GHz] 完成 {TRIGGERS_PER_FREQUENCY} 次 Trigger"
            )

            before_retune = device.status(refresh=True).capabilities
            group_input = _counter_delta(
                before_retune.trigger_input_count, prepared.trigger_input_count
            )
            group_accepted = _counter_delta(
                before_retune.trigger_accepted_count, prepared.trigger_accepted_count
            )
            if group_input != int(TRIGGERS_PER_FREQUENCY) or group_accepted != int(
                TRIGGERS_PER_FREQUENCY
            ):
                raise RuntimeError(
                    f"{frequency_ghz:.6f} GHz 组边界前计数为 "
                    f"输入/接受={group_input}/{group_accepted}，期望 "
                    f"{TRIGGERS_PER_FREQUENCY}/{TRIGGERS_PER_FREQUENCY}；"
                    "请暂停外部 Trigger"
                )

            if not _has_next_point(point_index):
                print("扫频点已完成；收到 Ctrl-C 可在无限扫频模式下停止")
                return 0

            # RFDC_APPLY requires disarmed/idle.  This also prevents a stale
            # finite record from accepting a Trigger while its NCO is changing.
            print("暂停外部 Trigger，停止播放并切换下一个频点")
            device.abort_mute()
            common.wait_state(device, PlaybackState.IDLE, "从卡切频前 IDLE", REARM_TIMEOUT_S)
            point_index += 1
            frequency_ghz = _frequency_for_point(point_index)
            _configure_frequency_and_arm(device, frequency_ghz, point_index)
            after_rearm = device.status(refresh=True).capabilities
            retune_input = _counter_delta(
                after_rearm.trigger_input_count, before_retune.trigger_input_count
            )
            retune_accepted = _counter_delta(
                after_rearm.trigger_accepted_count, before_retune.trigger_accepted_count
            )
            if retune_input or retune_accepted:
                raise RuntimeError(
                    "切频/重新 ARM 期间收到外部 Trigger "
                    f"(输入增量={retune_input}，接受增量={retune_accepted})；"
                    "请让外部源等待 PREPARED 后再继续"
                )

    except KeyboardInterrupt:
        print("收到 Ctrl-C，停止扫频并静音")
        return 0
    except (DriverError, AssertionError, RuntimeError, ValueError) as error:
        print(f"FAIL: {type(error).__name__}: {error}")
        return 2
    finally:
        common.cleanup(device)


if __name__ == "__main__":
    raise SystemExit(run())
