"""从卡跳过同步后，使用本地 UDP 软件 Trigger 独立发波的板级验收测试。

本测试只检查用户当前关心的最短路径：

1. 板卡必须烧写正式的 ``custom_xczu47dr_slave`` bitstream 和配套固件；
2. XS17 接入与 bitstream 匹配的参考时钟（10 MHz 和 250 MHz bitstream 不可混用）；
3. XS20 保持悬空，不提供外部 SYNC；
4. 驱动显式调用 ``bypass_sync()``，只绕过从卡的同步门控；
5. 驱动调用 ``trigger()`` 发送本地 UDP 软件 Trigger，使本板进入 RUNNING。

XS18 和 XS19 在本测试中都不参与，因此不需要连接 XS18 -> XS19。特别注意：
``trigger()`` 不会在 XS18 上输出物理脉冲；只有 ``emit_trigger()`` 才会驱动 XS18。

测试通过只证明 RFCTRL2、同步旁路、波形上传和数字播放状态机路径可工作。
RF 输出的频率、幅度和波形质量仍必须用示波器或频谱仪测量。

运行方式：

    PYTHONPATH=software python -m dr47.hardware_slave_bypass_software_trigger_test

运行前在本文件顶部填写网络配置。脚本固定执行广播发现、从卡角色确认、目标 IP
分配和回读验证，不接受命令行网络参数。
"""

from __future__ import annotations

import time

import numpy as np

from .capabilities import PlaybackState
from .device import Dr47Device
from .errors import DriverError
from .hardware_test_network import (
    BoardNetworkAssignment,
    discover_and_provision_boards,
)
from .waveforms import (
    iq_duration_to_interleaved_sample_count,
    make_iq_gaussian_sine_interleaved,
    place_interleaved_iq_in_record,
)


# 以下网络参数对应当前实验室单板环境。所有参数直接在代码中配置。
# 目标 IP 改到其他子网时，还要给主机网卡增加对应网段地址，并修改
# CONTROL_SOURCE_IP、TARGET_SUBNET_MASK 和 TARGET_GATEWAY。
BOARD_PORT = 1234
UDP_INTERFACE = "enp225s0f1"
DISCOVERY_SOURCE_IP = "169.254.250.11"
DISCOVERY_SOURCE_CIDR = "169.254.250.11/16"
DISCOVERY_BROADCAST_IP = "169.254.255.255"
CONTROL_SOURCE_IP = "169.254.250.11"

BOARD_TARGET_IP = "169.254.100.102"
TARGET_SUBNET_MASK = "255.255.0.0"
TARGET_GATEWAY = "0.0.0.0"
BOARD_DEVICE_UID = ""  # 多块从卡同时在线时必须填写目标 UID。
BOARD_TARGET_MAC = None  # None 表示保留 DNA 派生 MAC。

def _status(device: Dr47Device, label: str):
    """从板卡刷新状态，并打印本测试最关心的同步与 Trigger 字段。"""

    status = device.status(refresh=True)
    caps = status.capabilities
    print(
        f"{label}: 播放状态={status.state.value}, 同步角色={caps.sync_role}, "
        f"同步模式={caps.sync_mode}, XS20已见={caps.sync_seen}, "
        f"Trigger门控可用={caps.sync_link_ready}, "
        f"Trigger计数(输入/接受/输出)={caps.trigger_input_count}/"
        f"{caps.trigger_accepted_count}/{caps.trigger_output_count}"
    )
    return status


def _wait_for_state(
    device: Dr47Device,
    expected: PlaybackState,
    label: str,
    timeout_s: float = 3.0,
) -> None:
    """轮询板卡真实状态，避免仅凭 UDP 命令 ACK 判断播放已经开始。"""

    deadline = time.monotonic() + timeout_s
    last = None
    while time.monotonic() < deadline:
        last = device.status(refresh=True)
        if last.state is expected:
            return
        time.sleep(0.02)
    actual = "未知" if last is None else last.state.value
    raise AssertionError(
        f"{label}超时：期望状态 {expected.value}，板卡实际状态 {actual}"
    )


def _make_gaussian_record(
    *,
    baseband_frequency_ghz: float,
    duration_ns: float,
    delay_ns: float,
    record_duration_ns: float,
    amplitude: float,
    sample_rate_hz: float = 400_000_000.0,
    phase_rad: float = 0.0,
) -> np.ndarray:
    """生成具有指定包络、延迟和基带频率的高斯 IQ 记录。

    上传的数据仍是 I0,Q0,I1,Q1,... 的 int16 复基带：

    * ``make_iq_gaussian_sine_interleaved`` 生成有限长度高斯包络；
    * ``baseband_frequency_ghz`` 必须在当前 400 MS/s 复基带的 +/-0.2 GHz 内；
    * RFDC NCO 载波不是此函数参数，由调用方配置到 ``set_xy_nco_frequency``；
    * ``place_interleaved_iq_in_record`` 前置零实现可控延迟，尾部零保证记录完整。
    """

    sample_rate_hz = float(sample_rate_hz)
    duration_s = float(duration_ns) * 1e-9
    if not 0.0 < float(amplitude) <= 1.0:
        raise ValueError("amplitude must be in (0, 1]")
    if abs(float(baseband_frequency_ghz) * 1e9) > sample_rate_hz / 2.0:
        raise ValueError("baseband_frequency_ghz exceeds the complex-sample Nyquist limit")
    if float(delay_ns) < 0.0:
        raise ValueError("delay_ns must be non-negative")
    if float(delay_ns) + float(duration_ns) > float(record_duration_ns):
        raise ValueError("delay_ns + duration_ns must not exceed record_duration_ns")
    active_count = iq_duration_to_interleaved_sample_count(duration_s, sample_rate_hz)
    active = make_iq_gaussian_sine_interleaved(
        frequency_hz=float(baseband_frequency_ghz) * 1e9,
        phase_rad=float(phase_rad),
        amplitude=round(float(amplitude) * 32767.0),
        sample_rate_hz=sample_rate_hz,
        duration_s=duration_s,
        sample_count=active_count,
        # 与网页 XY 手动波形一致：FWHM 为脉冲时长的一半。
        fwhm_s=duration_s / 2.0,
        q_sign=-1,
        hls_xy_drag=False,
    )
    record = place_interleaved_iq_in_record(
        active,
        delay_s=float(delay_ns) * 1e-9,
        record_duration_s=float(record_duration_ns) * 1e-9,
        sample_rate_hz=sample_rate_hz,
    )
    return record


def _prepare_gaussian_waveform(
    device: Dr47Device,
    *,
    rf_nco_frequency_ghz: float,
    baseband_frequency_ghz: float,
    duration_ns: float,
    delay_ns: float,
    record_duration_ns: float,
    amplitude: float,
    gain: float,
    loop: bool,
    sample_rate_hz: float = 400_000_000.0,
    phase_rad: float = 0.0,
) -> None:
    """按显式参数配置 CH1、上传延迟高斯记录并 ARM。"""

    # 记录包含前置延迟、有限高斯包络和尾部零。调用方可以根据 ILA 或
    # 示波器捕获窗口选择记录长度与是否循环。
    iq = _make_gaussian_record(
        baseband_frequency_ghz=baseband_frequency_ghz,
        duration_ns=duration_ns,
        delay_ns=delay_ns,
        record_duration_ns=record_duration_ns,
        amplitude=amplitude,
        sample_rate_hz=sample_rate_hz,
        phase_rad=phase_rad,
    )
    print(
        f"波形：RF NCO={rf_nco_frequency_ghz:g} GHz，基带={baseband_frequency_ghz:g} GHz，"
        f"高斯脉冲={duration_ns:g} ns，延迟={delay_ns:g} ns，"
        f"记录={record_duration_ns:g} ns，循环={loop}"
    )

    # 高层驱动的 NCO 单位为 GHz；RF 载波在 RFDC 内部产生。
    device.set_xy_nco_frequency(1, rf_nco_frequency_ghz)
    device.set_gain("xy", 1, gain, gain_type="norm")
    device.set_qc_on_off("xy", 1, "on")
    device.commit()

    # auto_start=False 保证上传不会直接播放。loop 为 True 时每个记录重复一次；
    # 为 False 时本地 UDP Trigger 只播放一次有限记录。
    device.upload_waveforms(
        {1: iq},
        wave_formats={1: "interleaved_iq"},
        auto_start=False,
        loop=loop,
        channel_delays={1: 0},
        instruction_repeats=3,
    )
    device.arm(channel_mask=0x01)
    _wait_for_state(device, PlaybackState.PREPARED, "ARM 后等待 DAC PREPARED")


def run() -> int:
    """执行完整上板验收；成功返回 0，驱动错误或断言失败返回 2。"""

    device = None
    try:
        # 第 1 步：广播发现全部板卡，读取 bitstream 角色，选择从卡并配置
        # 本文件顶部指定的目标 IP。配置后会从目标 IP 回读同一个 device_uid。
        enrolled = discover_and_provision_boards(
            [
                BoardNetworkAssignment(
                    label="从卡",
                    sync_role="slave",
                    ip=BOARD_TARGET_IP,
                    device_uid=BOARD_DEVICE_UID,
                    mac=BOARD_TARGET_MAC,
                    subnet_mask=TARGET_SUBNET_MASK,
                    gateway=TARGET_GATEWAY,
                )
            ],
            interface=UDP_INTERFACE,
            discovery_source_ip=DISCOVERY_SOURCE_IP,
            discovery_source_cidr=DISCOVERY_SOURCE_CIDR,
            control_source_ip=CONTROL_SOURCE_IP,
            broadcast_ip=DISCOVERY_BROADCAST_IP,
            port=BOARD_PORT,
        )[0]

        # 第 2 步：使用刚刚分配并验证过的目标 IP 建立正式控制连接。
        device = Dr47Device(
            ip=enrolled.ip,
            port=BOARD_PORT,
            udp_interface=UDP_INTERFACE,
            udp_source_ip=CONTROL_SOURCE_IP,
            timeout_s=1.0,
            retries=2,
            batch_mode=True,
        )
        print(
            f"正在通过 {UDP_INTERFACE} 连接从卡 {enrolled.ip}:{BOARD_PORT}，"
            f"UID={enrolled.device_uid}"
        )
        device.connect()
        initial = _status(device, "初始状态")
        caps = initial.capabilities
        if not (caps.rfdc_ready and caps.dac_mts_ready and caps.nco_sync_ready):
            raise AssertionError("RFDC、DAC MTS 或 NCO SYSREF 尚未就绪")
        if caps.sync_role != "slave":
            raise AssertionError(
                "本测试要求烧写 custom_xczu47dr_slave bitstream，"
                f"当前板卡角色为 {caps.sync_role!r}"
            )

        # 第 3 步：清理上一次运行留下的状态。模式只能在 IDLE 时切换。
        if initial.state is not PlaybackState.IDLE:
            print("检测到板卡不是 IDLE，先发送 ABORT_MUTE 停止并静音")
            device.abort_mute()
            _wait_for_state(device, PlaybackState.IDLE, "清理旧播放状态")

        # 第 4 步：显式跳过从卡的 XS20 同步门控。
        # bypass 只授予本地运行权限，不能伪造真实的 XS20 SYNC 事件。
        device.bypass_sync()
        bypass = _status(device, "执行 bypass_sync() 后")
        if bypass.capabilities.sync_mode != "bypass":
            raise AssertionError("板卡没有进入 bypass 同步模式")
        if bypass.capabilities.sync_seen:
            raise AssertionError("XS20 悬空时 sync_seen 不应被 bypass 伪造为 True")
        if not bypass.capabilities.sync_link_ready:
            raise AssertionError("bypass 后 Trigger 门控仍未放开")

        # 第 5 步：配置 RFDC、上传 CH1 波形并 ARM。
        #
        # 所有波形参数都在调用处显式给出，便于测试脚本直接改参数，
        # 也避免隐藏在模块级配置常量中。这里的示例是：
        #   - RFDC 内部 NCO 产生 1 GHz 射频载波；
        #   - 上传 0 GHz 基带高斯包络（60 ns）；
        #   - 在 10 us 记录的开头延迟 100 ns 后才出现脉冲；
        #   - 循环播放，方便 ILA/示波器捕获。
        _prepare_gaussian_waveform(
            device,
            rf_nco_frequency_ghz=1.0,
            baseband_frequency_ghz=0.0,
            duration_ns=60.0,
            delay_ns=100.0,
            record_duration_ns=10_000.0,
            amplitude=1.0,
            gain=1.0,
            loop=True,
            sample_rate_hz=400_000_000.0,
            phase_rad=0.0,
        )
        prepared = _status(device, "波形上传并 ARM 后")
        if prepared.state is not PlaybackState.PREPARED:
            raise AssertionError("ARM 后板卡没有进入 PREPARED")

        # 记录物理 Trigger 计数器。下一步使用 trigger()，它只走 UDP 本地路径，
        # 因而 XS19 输入计数和 XS18 输出计数都不应增加。
        before = prepared.capabilities

        # 第 6 步：发送本地 UDP 软件 Trigger。从卡自己 Trigger 。
        # 此处刻意不调用 emit_trigger()，也不依赖 XS18 -> XS19 电缆。
        device.trigger()
        _wait_for_state(device, PlaybackState.RUNNING, "本地 UDP Trigger 后等待 RUNNING")
        running = _status(device, "本地 UDP Trigger 后")
        after = running.capabilities

        if running.state is not PlaybackState.RUNNING:
            raise AssertionError("本地 UDP Trigger 没有启动播放")
        if after.sync_seen:
            raise AssertionError("本地播放期间不应凭空出现 XS20 SYNC")
        if after.trigger_input_count != before.trigger_input_count:
            raise AssertionError("本地 UDP Trigger 不应增加 XS19 输入计数")
        if after.trigger_output_count != before.trigger_output_count:
            raise AssertionError("本地 UDP Trigger 不应增加 XS18 输出计数")

        print(
            "PASS: 从卡在 bypass 模式下通过本地 UDP 软件 Trigger 独立进入 "
            "RUNNING；未伪造 XS20 同步，也未使用 XS18/XS19 回环。"
        )
        print("提示：RF 频率、幅度和波形质量仍需使用示波器或频谱仪确认。")
        return 0
    except (DriverError, AssertionError) as error:
        print(f"FAIL: {type(error).__name__}: {error}")
        return 2
    finally:
        # 无论测试成功还是失败，都尽力停止播放并静音，避免板卡持续输出。
        try:
            if device is not None and device.connected:
                device.abort_mute()
        except DriverError:
            pass
        if device is not None:
            device.close()


if __name__ == "__main__":
    raise SystemExit(run())
