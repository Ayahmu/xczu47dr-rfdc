"""单块从卡等待外部 SYNC/Trigger 后发波的板级测试。

本脚本专门用于“082 已烧写 slave bitstream，由主卡或其他设备控制”的场景。
脚本本身不会发送 SYNC，也不会发送 Trigger，完整流程是：

1. 通过广播发现从卡，并确认发现到的 bitstream 角色是 ``slave``；
2. 连接从卡并强制设置为 ``external`` 同步模式；
3. 等待一次新的 XS20 SYNC，以及本次 SYNC 对应的 MTS/NCO 对齐完成；
4. SYNC 完成后才配置 RFDC、上传 CH1 波形并 ARM；
5. ARM 后持续等待 XS19 Trigger；每个被硬件接受的 Trigger 只播放一次有限波形；
6. 每条波形结束后，FPGA 自动重新预取并回到 PREPARED，等待下一次 Trigger；
7. 测试结束时 ABORT_MUTE，避免下次运行残留播放状态。

不会调用 ``sync()``、``bypass_sync()``、``trigger()`` 或 ``emit_trigger()``。
因此，运行到“等待 XS19 Trigger”后，需要由主卡 XS18、国盾设备或其他外部
Trigger 源向本卡 XS19 输入脉冲。

运行：

    PYTHONPATH=software python -m dr47.examples.hardware_slave_wait_sync_trigger_test

网络、波形和超时参数都在本文件顶部配置，不使用命令行参数。250 MHz 分支运行
时，XS17 必须输入 250 MHz；10 MHz 主线运行时，使用对应主线版本的工件。
"""

from __future__ import annotations

import os
import time

import numpy as np

from ..capabilities import PlaybackState
from ..device import Dr47Device
from ..errors import DriverError
from ..network import connect_discovered, discover_boards
from ..waveforms import (
    iq_duration_to_interleaved_sample_count,
    make_iq_gaussian_sine_interleaved,
    place_interleaved_iq_in_record,
)


# --------------------------- 网络配置 ---------------------------
BOARD_PORT = 1234
UDP_INTERFACE = os.environ.get("RFSOC_UDP_INTERFACE", "enp1s0f0")
DISCOVERY_SOURCE_IP = os.environ.get("RFSOC_DISCOVERY_SOURCE_IP", "169.254.250.11")
DISCOVERY_SOURCE_CIDR = os.environ.get(
    "RFSOC_DISCOVERY_SOURCE_CIDR", "169.254.250.11/16"
)
DISCOVERY_BROADCAST_IP = os.environ.get(
    "RFSOC_DISCOVERY_BROADCAST_IP", "169.254.255.255"
)

# 082 的 device_uid 可在第一次 discover 输出中填入。只连接一块从卡时可以留空；
# 交换机上有多块 slave 时必须填写，避免选错板卡。
BOARD_DEVICE_UID = ""
EXPECTED_SYNC_ROLE = "slave"
# 如果已知 082 当前临时 IP，可以填写；留空表示只按 slave 角色和 UID 选择。
BOARD_IP_HINT = ""

# --------------------------- 测试参数 ---------------------------
POLL_INTERVAL_S = 0.20
RF_NCO_GHZ = 1.0
BASEBAND_GHZ = 0.0
PULSE_DURATION_NS = 60.0
PULSE_DELAY_NS = 100.0
RECORD_DURATION_NS = 10_000.0
AMPLITUDE = 1.0
GAIN = 1.0
SAMPLE_RATE_HZ = 400_000_000.0
CHANNEL_MASK = 0x01
# One Trigger must launch exactly one finite record. The RTL automatically
# refills and re-enters PREPARED after the record drains.
LOOP_WAVEFORM = False


def _print_status(device: Dr47Device, label: str):
    """读取并打印同步、对齐、Trigger 和播放状态。"""

    status = device.status(refresh=True)
    caps = status.capabilities
    print(
        f"{label}: state={status.state.value}, role={caps.sync_role}, "
        f"mode={caps.sync_mode}, sync_seen={caps.sync_seen}, "
        f"sync_ready={caps.sync_link_ready}, align_busy={caps.sync_align_busy}, "
        f"align_epoch={caps.sync_alignment_epoch}, "
        f"trigger(in/accepted/out)={caps.trigger_input_count}/"
        f"{caps.trigger_accepted_count}/{caps.trigger_output_count}"
    )
    return status


def _wait_state(device: Dr47Device, expected: PlaybackState, label: str) -> None:
    """等待板卡状态真正更新，不能只依据命令 ACK 判断。"""

    deadline = time.monotonic() + 5.0
    last = None
    while time.monotonic() < deadline:
        last = device.status(refresh=True)
        if last.state is expected:
            return
        time.sleep(0.02)
    actual = "unknown" if last is None else last.state.value
    raise AssertionError(f"{label} timeout: expected={expected.value}, actual={actual}")


def _select_slave():
    """广播发现并选择 082 对应的 slave，不修改板卡网络配置。"""

    print(
        f"通过 {UDP_INTERFACE} 从 {DISCOVERY_SOURCE_IP} 广播 NETWORK_GET，"
        f"目标 {DISCOVERY_BROADCAST_IP}:{BOARD_PORT}"
    )
    boards = discover_boards(
        interface=UDP_INTERFACE,
        source_ip=DISCOVERY_SOURCE_IP,
        source_cidr=DISCOVERY_SOURCE_CIDR,
        broadcast_ip=DISCOVERY_BROADCAST_IP,
        port=BOARD_PORT,
        timeout_s=1.0,
        rounds=3,
    )
    identity_candidates = [
        board
        for board in boards
        if (not BOARD_DEVICE_UID or board.device_uid.lower() == BOARD_DEVICE_UID.lower())
        and (not BOARD_IP_HINT or board.current_ip == BOARD_IP_HINT)
    ]
    # 新版 NETWORK_GET 会带 build_profile；旧版报文可能为空。profile 有值时
    # 严格筛选 slave，profile 为空时保留身份候选，随后由连接后的 STATUS 再确认角色。
    profiled_candidates = [
        board for board in identity_candidates
        if board.build_profile and board.build_profile.lower().endswith("slave")
    ]
    candidates = profiled_candidates or identity_candidates
    if not candidates:
        details = "; ".join(
            f"UID={b.device_uid},IP={b.current_ip},MAC={b.current_mac},PROFILE={b.build_profile}"
            for b in boards
        )
        raise DriverError(f"没有发现目标 slave；发现结果：{details or '无'}")
    if len(candidates) > 1:
        details = "; ".join(
            f"UID={b.device_uid},IP={b.current_ip},MAC={b.current_mac}" for b in candidates
        )
        raise DriverError(f"发现多个候选 slave，请填写 BOARD_DEVICE_UID：{details}")
    board = candidates[0]
    print(
        f"发现 082 slave：UID={board.device_uid}，IP={board.current_ip}，"
        f"MAC={board.current_mac}，PROFILE={board.build_profile or 'unknown'}"
    )
    return board


def _wait_external_sync(device: Dr47Device, before_epoch: int) -> None:
    """等待脚本启动后发生的新一次真实 XS20 SYNC。"""

    print("等待新的 XS20 SYNC；本脚本不会调用 sync() 或 bypass_sync()")
    while True:
        # 等待阶段只轮询，不重复打印整行 STATUS，避免终端被刷屏。
        status = device.status(refresh=True)
        caps = status.capabilities
        # RFCTRL2 STATUS 公开的是“固件已完成对齐”的 epoch，而不是 PL 内部
        # sync_event_epoch。该 epoch 变化表示发生了新的 SYNC 且本次 MTS/NCO
        # 对齐已被固件确认，避免把旧的 sync_seen 状态误当成新 SYNC。
        if (
            caps.sync_alignment_epoch != before_epoch
            and caps.sync_seen
            and caps.sync_link_ready
            and not caps.sync_align_busy
            and not caps.sync_align_failed
            and caps.dac_mts_ready
            and caps.nco_sync_ready
        ):
            print(
                f"PASS: 收到新的 XS20 SYNC，alignment_epoch={caps.sync_alignment_epoch}"
            )
            return
        time.sleep(POLL_INTERVAL_S)


def _make_waveform() -> np.ndarray:
    """生成 CH1 的 1 GHz RF NCO、60 ns 高斯包络记录。"""

    duration_s = PULSE_DURATION_NS * 1e-9
    active_count = iq_duration_to_interleaved_sample_count(duration_s, SAMPLE_RATE_HZ)
    active = make_iq_gaussian_sine_interleaved(
        frequency_hz=BASEBAND_GHZ * 1e9,
        phase_rad=0.0,
        amplitude=round(AMPLITUDE * 32767.0),
        sample_rate_hz=SAMPLE_RATE_HZ,
        duration_s=duration_s,
        sample_count=active_count,
        fwhm_s=duration_s / 2.0,
        q_sign=-1,
        hls_xy_drag=False,
    )
    return place_interleaved_iq_in_record(
        active,
        delay_s=PULSE_DELAY_NS * 1e-9,
        record_duration_s=RECORD_DURATION_NS * 1e-9,
        sample_rate_hz=SAMPLE_RATE_HZ,
    )


def _prepare_waveform_after_sync(device: Dr47Device) -> None:
    """仅在 SYNC 对齐完成后配置、上传和 ARM。"""

    record = _make_waveform()
    print(
        f"SYNC 完成，开始上传波形：RF NCO={RF_NCO_GHZ:g} GHz，"
        f"高斯={PULSE_DURATION_NS:g} ns，记录内延迟={PULSE_DELAY_NS:g} ns，"
        f"loop={LOOP_WAVEFORM}"
    )
    device.set_xy_nco_frequency(1, RF_NCO_GHZ)
    device.set_gain("xy", 1, GAIN, gain_type="norm")
    device.set_qc_on_off("xy", 1, "on")
    device.commit()
    device.upload_waveforms(
        {1: record},
        wave_formats={1: "interleaved_iq"},
        auto_start=False,
        loop=LOOP_WAVEFORM,
        channel_delays={1: 0},
        instruction_repeats=3,
    )
    device.arm(channel_mask=CHANNEL_MASK)
    _wait_state(device, PlaybackState.PREPARED, "ARM 后等待 PREPARED")
    print("PASS: 波形上传完成，从卡已 ARM，等待连续 XS19 Trigger")


def _wait_external_triggers(
    device: Dr47Device,
    before_input_count: int,
    before_accepted_count: int,
) -> None:
    """持续监控 XS19 Trigger；每次接受都对应一条有限波形。"""

    print(
        "持续等待 XS19 Trigger；每个接受的 Trigger 播放一条有限波形。"
        "按 Ctrl-C 停止并执行 ABORT_MUTE。"
    )
    input_count = before_input_count
    accepted_count = before_accepted_count
    while True:
        status = device.status(refresh=True)
        caps = status.capabilities
        new_inputs = (caps.trigger_input_count - input_count) & 0xFFFFFFFF
        new_accepted = (caps.trigger_accepted_count - accepted_count) & 0xFFFFFFFF
        if new_accepted:
            print(
                f"Trigger accepted +{new_accepted}，总接受={caps.trigger_accepted_count}；"
                "每个接受事件对应一条有限波形。"
            )
        if new_inputs > new_accepted:
            print(
                f"WARNING: XS19 输入 +{new_inputs}，但仅接受 +{new_accepted}；"
                "有 Trigger 到达时板卡尚未重新 PREPARED，请增大 Trigger 间隔。"
            )
        input_count = caps.trigger_input_count
        accepted_count = caps.trigger_accepted_count
        time.sleep(POLL_INTERVAL_S)


def run() -> int:
    """执行等待 SYNC → 上传/ARM → 等待 Trigger 的完整流程。"""

    device: Dr47Device | None = None
    try:
        board = _select_slave()
        device = connect_discovered(board, timeout_s=1.0, retries=2)
        initial = _print_status(device, "初始状态")
        caps = initial.capabilities
        if caps.sync_role != EXPECTED_SYNC_ROLE:
            raise AssertionError(f"需要 slave bitstream，实际角色是 {caps.sync_role!r}")
        if not (caps.rfdc_ready and caps.dac_mts_ready and caps.nco_sync_ready):
            raise AssertionError("RFDC、DAC MTS 或 NCO SYSREF 尚未就绪")
        if initial.state is not PlaybackState.IDLE:
            print("清理上一次残留播放状态")
            device.abort_mute()
            _wait_state(device, PlaybackState.IDLE, "ABORT_MUTE")

        before_epoch = caps.sync_alignment_epoch
        before_input_count = caps.trigger_input_count
        before_accepted_count = caps.trigger_accepted_count
        device.require_external_sync()
        _wait_external_sync(device, before_epoch)
        _prepare_waveform_after_sync(device)
        _wait_external_triggers(device, before_input_count, before_accepted_count)
    except KeyboardInterrupt:
        print("收到 Ctrl-C，停止等待并清理播放状态")
        return 0
    except (DriverError, AssertionError) as error:
        print(f"FAIL: {type(error).__name__}: {error}")
        return 2
    finally:
        if device is not None:
            try:
                if device.connected:
                    device.abort_mute()
            except DriverError:
                pass
            device.close()


if __name__ == "__main__":
    raise SystemExit(run())
