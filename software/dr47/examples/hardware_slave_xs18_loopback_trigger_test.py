"""XS18→XS19 自环 Trigger 测量脚本（单板，跳过 SYNC）。

对应的接线（XS20_TRIG_OUT=1 那套 bitstream）：

    XS17 -> 10 MHz 参考
    XS18 -> XS19    板卡自己触发自己
    XS20 -> 示波器  Trigger 时间基准
    CH1  -> 示波器  50 Ω 端接

和 hardware_slave_bypass_software_trigger_test.py 的区别：

* 不做广播发现，直接按 IP 连接。发现流程会强制校验 bitstream 角色，
  而本测试只关心 Trigger 通路。
* 用 emit_trigger() 让 XS18 打出物理脉冲，经短接线进 XS19。这条路走的是
  新的 dac_axis_clk 直采路径，而 device.trigger() 走的是旧的 hmc_pl_clk
  路径——两者都会被 dac_trigger_latency_probe 记录下来做对比。
* loop=False，每个 Trigger 只播放一条有限波形。

跑完之后用 software/trigger_latency_report.py 读 ILA 里累计的
trig_lat_delta_min/max，那是 hmc_pl_clk 绕行贡献的抖动实测值。
"""

from __future__ import annotations

import os
import time

from ..device import Dr47Device
from ..errors import DriverError
from ..capabilities import PlaybackState
from .hardware_slave_bypass_software_trigger_test import (
    _prepare_gaussian_waveform,
    _wait_for_state,
)


BOARD_IP = os.environ.get("RFSOC_BOARD_IP", "169.254.100.101")
BOARD_PORT = 1234
UDP_INTERFACE = os.environ.get("RFSOC_UDP_INTERFACE", "enp1s0f0")
CONTROL_SOURCE_IP = os.environ.get("RFSOC_CONTROL_SOURCE_IP", "169.254.250.11")

TRIGGER_COUNT = int(os.environ.get("RFSOC_TRIGGER_COUNT", "200"))
TRIGGER_INTERVAL_S = float(os.environ.get("RFSOC_TRIGGER_INTERVAL_S", "0.1"))

RF_NCO_GHZ = float(os.environ.get("RFSOC_RF_NCO_GHZ", "0.5"))
GAUSSIAN_NS = float(os.environ.get("RFSOC_GAUSSIAN_NS", "60.0"))
DELAY_NS = float(os.environ.get("RFSOC_DELAY_NS", "100.0"))
RECORD_NS = float(os.environ.get("RFSOC_RECORD_NS", "10000.0"))


def _counts(device: Dr47Device, label: str):
    caps = device.status(refresh=True).capabilities
    print(
        f"{label}: 状态={device.status(refresh=False).state.value} "
        f"角色={caps.sync_role} 模式={caps.sync_mode} "
        f"门控={caps.sync_link_ready} "
        f"Trigger(输入/接受/输出)={caps.trigger_input_count}/"
        f"{caps.trigger_accepted_count}/{caps.trigger_output_count}"
    )
    return caps


def run() -> int:
    device = Dr47Device(
        ip=BOARD_IP,
        port=BOARD_PORT,
        udp_interface=UDP_INTERFACE,
        udp_source_ip=CONTROL_SOURCE_IP,
        timeout_s=2.0,
        retries=3,
    )
    try:
        device.connect()
        print(f"已连接 {BOARD_IP}:{BOARD_PORT} via {UDP_INTERFACE}")
        device.abort_mute()
        before = _counts(device, "连接后")

        # 单板无 XS20 SYNC（这套 bitstream 里 XS20 是 Trigger 输出），所以
        # 必须放开同步门控，否则 Trigger 会被 sync_link_ready 拒掉。
        if not before.sync_link_ready:
            try:
                device.bypass_sync()
                print("已调用 bypass_sync() 放开同步门控")
            except DriverError as exc:
                print(f"警告：bypass_sync() 被拒绝（{exc}）；继续尝试")
            _counts(device, "bypass 后")

        _prepare_gaussian_waveform(
            device,
            rf_nco_frequency_ghz=RF_NCO_GHZ,
            baseband_frequency_ghz=0.0,
            duration_ns=GAUSSIAN_NS,
            delay_ns=DELAY_NS,
            record_duration_ns=RECORD_NS,
            amplitude=1.0,
            gain=1.0,
            loop=False,          # 每个 Trigger 播放一次有限波形
            sample_rate_hz=400_000_000.0,
            phase_rad=0.0,
        )
        armed = _counts(device, "上传并 ARM 后")
        if device.status(refresh=False).state is not PlaybackState.PREPARED:
            print("FAIL: ARM 之后没有进入 PREPARED")
            return 2

        base_in = armed.trigger_input_count
        base_acc = armed.trigger_accepted_count
        base_out = armed.trigger_output_count
        print(f"\n开始 {TRIGGER_COUNT} 次 XS18->XS19 自环 Trigger "
              f"(间隔 {TRIGGER_INTERVAL_S * 1000:.0f} ms)\n")

        missed = 0
        rearms = 0
        for index in range(1, TRIGGER_COUNT + 1):
            # 有限波形播完后执行器停在 armed 并且无法再回到 PREPARED：10 MHz
            # 主线没有"逐 Trigger 单次播放"那个特性（250 MHz 分支 a33c1c9 才
            # 引入），armed 状态下重新 arm 不会重新预取。所以每次都重新上传
            # 一遍记录。重新上传发生在两次 Trigger 之间，不影响被测的
            # Trigger->RF 延迟本身。
            if device.status(refresh=True).state is not PlaybackState.PREPARED:
                try:
                    device.abort_mute()
                    _prepare_gaussian_waveform(
                        device,
                        rf_nco_frequency_ghz=RF_NCO_GHZ,
                        baseband_frequency_ghz=0.0,
                        duration_ns=GAUSSIAN_NS,
                        delay_ns=DELAY_NS,
                        record_duration_ns=RECORD_NS,
                        amplitude=1.0,
                        gain=1.0,
                        loop=False,
                        sample_rate_hz=400_000_000.0,
                        phase_rad=0.0,
                    )
                    rearms += 1
                except (DriverError, AssertionError) as exc:
                    print(f"[{index:03d}] 无法回到 PREPARED：{exc}")
                    missed += 1
                    continue
            # XS18 打出物理脉冲；短接线把它送进 XS19，同时 XS20 给示波器基准。
            device.emit_trigger()
            time.sleep(TRIGGER_INTERVAL_S)
            if index % 20 == 0 or index == TRIGGER_COUNT or index <= 2:
                _counts(device, f"[{index:03d}/{TRIGGER_COUNT}]")

        final = _counts(device, "\n结束")
        d_in = final.trigger_input_count - base_in
        d_acc = final.trigger_accepted_count - base_acc
        d_out = final.trigger_output_count - base_out
        print(f"\n本轮增量：XS18 输出={d_out}  XS19 输入={d_in}  接受={d_acc}")
        print(f"重新 ARM 次数={rearms}  无法回到 PREPARED 次数={missed}")
        if d_out == 0:
            print("FAIL: XS18 一次都没有输出——检查 EMIT_TRIGGER 是否被同步门控拒绝")
            return 2
        if d_in == 0:
            print("FAIL: XS19 没有收到任何脉冲——检查 XS18/XS19 短接线")
            return 2
        print("\n接着运行以读取 ILA 里累计的抖动实测值：")
        print("  python3 software/trigger_latency_report.py --role slave_trigout \\")
        print("      --jtag-serial 210512180082 \\")
        print("      --ltx artifacts/custom_xczu47dr_slave_trigout.ltx")
        return 0
    except DriverError as exc:
        print(f"FAIL: DriverError: {exc}")
        return 2
    finally:
        try:
            device.close()
        except Exception:
            pass


if __name__ == "__main__":
    raise SystemExit(run())
