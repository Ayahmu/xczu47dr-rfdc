"""单块从卡 bypass/Trigger 两种测试流程。

通过修改本文件顶部的 ``TEST_MODE`` 选择测试模式，不使用命令行参数：

``bypass_software_trigger``
    XS20 不接同步源；驱动调用 ``bypass_sync()`` 后上传一次有限波形并 ARM，
    然后重复调用 ``device.trigger()``。每个软件 Trigger 播放一条波形。

``bypass_external_trigger``
    XS20 同样不参与门控；驱动调用 ``bypass_sync()`` 后上传一次有限波形并 ARM，
    之后只等待 XS19 物理 Trigger。每个 XS19 Trigger 播放一条波形。

两种模式都不会调用 ``sync()``。bypass 只是跳过从卡的 XS20 门控，不会伪造
``sync_seen``。波形上传/预取和自动重新 PREPARED 由 FPGA 负责；触发过快时不
排队，脚本会报告输入计数和接受计数的差异。
"""

from __future__ import annotations

import time

from ..capabilities import PlaybackState
from ..errors import DriverError
from ..hardware_test_network import BoardNetworkAssignment
from . import _common as common


TEST_MODE = "bypass_software_trigger"
VALID_MODES = {"bypass_software_trigger", "bypass_external_trigger"}
TRIGGER_COUNT = 20
TRIGGER_INTERVAL_S = 0.020


def _wait_prepared(device, label: str) -> None:
    common.wait_state(device, PlaybackState.PREPARED, f"{label} PREPARED", timeout_s=10.0)


def _run_software_triggers(device) -> None:
    """重复发送软件 Trigger；每次只启动一条有限记录。"""

    for index in range(1, TRIGGER_COUNT + 1):
        _wait_prepared(device, "从卡")
        before = device.status(refresh=True).capabilities
        device.trigger()
        common.wait_counter(
            device,
            "trigger_accepted_count",
            before.trigger_accepted_count,
            f"第 {index} 次软件 Trigger 接受",
        )
        print(f"[{index:02d}/{TRIGGER_COUNT}] 软件 Trigger -> 一条有限波形")
        time.sleep(TRIGGER_INTERVAL_S)


def _run_external_triggers(device) -> None:
    """无限等待 XS19 物理 Trigger，按计数变化打印接受结果。"""

    before = device.status(refresh=True).capabilities
    last_input = before.trigger_input_count
    last_accepted = before.trigger_accepted_count
    print("持续等待 XS19 Trigger；按 Ctrl-C 停止并执行 ABORT_MUTE")
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
            print("WARNING: Trigger 到达时播放器尚未 PREPARED，事件被忽略")
        time.sleep(common.POLL_INTERVAL_S)


def run() -> int:
    """执行发现/配置/连接、bypass、上传一次波形及所选 Trigger 流程。"""

    if TEST_MODE not in VALID_MODES:
        print(f"FAIL: TEST_MODE={TEST_MODE!r} 不在 {sorted(VALID_MODES)} 中")
        return 2
    device = None
    try:
        enrolled = common.enroll(
            [
                BoardNetworkAssignment(
                    label="从卡",
                    sync_role="slave",
                    ip=common.SLAVE_TARGET_IP,
                    device_uid=common.SLAVE_DEVICE_UID,
                    match_mac=common.SLAVE_MATCH_MAC,
                    mac=common.SLAVE_TARGET_MAC,
                    subnet_mask=common.TARGET_SUBNET_MASK,
                    gateway=common.TARGET_GATEWAY,
                )
            ]
        )["slave"]
        device = common.new_device(enrolled)
        initial = common.show_status(device, "从卡初始")
        if initial.capabilities.sync_role != "slave":
            raise AssertionError("当前板卡不是 slave bitstream")
        common.wait_rfdc_ready(device, "从卡")
        common.ensure_idle(device, "从卡")

        # bypass 只打开本地运行权限，sync_seen 必须仍然为 False。
        device.bypass_sync()
        bypass = common.show_status(device, "bypass_sync() 后")
        if bypass.capabilities.sync_seen:
            raise AssertionError("bypass 不得伪造 sync_seen=True")
        if not bypass.capabilities.sync_link_ready:
            raise AssertionError("bypass 后 Trigger 门控未打开")

        record = common.make_gaussian_record()
        common.configure_and_arm(device, record, label="从卡")
        _wait_prepared(device, "从卡")
        if TEST_MODE == "bypass_software_trigger":
            _run_software_triggers(device)
        else:
            _run_external_triggers(device)
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

