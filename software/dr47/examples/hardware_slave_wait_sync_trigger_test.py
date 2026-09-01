"""正式从卡流程：等待外部 SYNC，再上传一次波形并等待 XS19 Trigger。

这是 250 MHz 工程的被动从卡入口。脚本只负责网络入网、连接、等待同步、上传
有限波形和 ARM；它不发送 SYNC，也不发送软件 Trigger。外部主卡、国盾设备或
其他同步源必须接到本卡 XS20，Trigger 源必须接到 XS19。

一次有效 Trigger 播放一次有限记录。波形上传/预取期间不接受 Trigger；播放完成
后由 FPGA 自动重新回到 PREPARED，脚本继续等待下一次 XS19 Trigger。按 Ctrl-C
退出，脚本会发送 ABORT_MUTE。

运行前确认：XS17 输入 250 MHz，主机网卡已配置 169.254.250.11/16，且修改本文件
顶部的 UID/IP 常量。所有网络配置保留在代码中，不增加命令行参数。
"""

from __future__ import annotations

import time

from ..capabilities import PlaybackState
from ..errors import DriverError
from ..hardware_test_network import BoardNetworkAssignment
from . import _common as common


EXPECTED_SYNC_ROLE = "slave"
BOARD_DEVICE_UID = common.SLAVE_DEVICE_UID
BOARD_MATCH_MAC = common.SLAVE_MATCH_MAC
BOARD_TARGET_IP = common.SLAVE_TARGET_IP
BOARD_TARGET_MAC = common.SLAVE_TARGET_MAC
# 每个 XS19 Trigger 只播放一条有限记录；不要改为 True。
LOOP_WAVEFORM = False


def _wait_external_sync(device, before_epoch: int) -> None:
    """无限等待新的 XS20 同步及其 MTS/NCO 对齐完成，不刷屏、不设置超时。"""

    print("等待新的 XS20 SYNC；本脚本不会调用 sync() 或 bypass_sync()")
    while True:
        status = device.status(refresh=True)
        caps = status.capabilities
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
                f"收到 XS20 SYNC，对齐完成：alignment_epoch={caps.sync_alignment_epoch}"
            )
            return
        time.sleep(common.POLL_INTERVAL_S)


def _wait_external_triggers(device, before_input: int, before_accepted: int) -> None:
    """无限等待 XS19；只报告计数变化，避免每次轮询输出整行状态。"""

    print("已 ARM，持续等待 XS19 Trigger；每个 accepted Trigger 播放一条波形")
    last_input = before_input
    last_accepted = before_accepted
    while True:
        caps = device.status(refresh=True).capabilities
        if caps.trigger_input_count != last_input:
            print(f"XS19 输入计数：{last_input} -> {caps.trigger_input_count}")
            last_input = caps.trigger_input_count
        if caps.trigger_accepted_count != last_accepted:
            print(
                f"Trigger 接受计数：{last_accepted} -> {caps.trigger_accepted_count}；"
                "本次对应一条有限波形"
            )
            last_accepted = caps.trigger_accepted_count
        if caps.trigger_input_count > caps.trigger_accepted_count:
            print("WARNING: 有 Trigger 到达时播放器尚未 PREPARED，过快事件被忽略")
        time.sleep(common.POLL_INTERVAL_S)


def run() -> int:
    """执行 discover → provision → wait SYNC → upload/ARM → wait Trigger。"""

    device = None
    try:
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
        initial = common.show_status(device, "初始状态")
        caps = initial.capabilities
        if caps.sync_role != EXPECTED_SYNC_ROLE:
            raise AssertionError(f"需要 slave bitstream，实际为 {caps.sync_role!r}")
        common.wait_rfdc_ready(device, "从卡")
        common.ensure_idle(device, "从卡")
        before_epoch = caps.sync_alignment_epoch
        before_input = caps.trigger_input_count
        before_accepted = caps.trigger_accepted_count
        device.require_external_sync()
        _wait_external_sync(device, before_epoch)
        record = common.make_gaussian_record()
        common.configure_and_arm(device, record, label="从卡")
        _wait_external_triggers(device, before_input, before_accepted)
        return 0
    except KeyboardInterrupt:
        print("收到 Ctrl-C，停止等待并静音")
        return 0
    except (DriverError, AssertionError) as error:
        print(f"FAIL: {type(error).__name__}: {error}")
        return 2
    finally:
        common.cleanup(device)


if __name__ == "__main__":
    raise SystemExit(run())
