"""一次 SYNC 后重复 Trigger 的主从延迟隔离测试。

本脚本专门回答一个问题：

    如果只同步一次，后面连续多次 Trigger，主从波形间延迟是否还会变化？

每轮都会重新上传同一条有限波形、ARM 两块板并触发一次，但不会再次调用
``SyncGroup.sync()``，因此不会重复执行 HMC7044 SYNC、DAC MTS 或 NCO 对齐。
这样可以把“每轮重新 SYNC 导致的变化”和“Trigger/播放启动路径导致的变化”分开。

示波器连接：

* 082 master CH1/vout00 -> 示波器通道 1；
* 081 slave CH1/vout00  -> 示波器通道 2；
* 两块板 XS17 接同一个 250 MHz 参考；
* 082 XS20 -> 081 XS20；
* 082 XS18 -> 081 XS19。

预期观察：

* 每一轮只出现一对 60 ns 高斯脉冲；
* 同一次 SYNC 后，如果 20 对波形的相对延迟仍跳变，问题在 Trigger/播放启动链；
* 如果同一次 SYNC 后延迟稳定，而“每轮重新 SYNC”的脚本才跳变，问题在 SYNC/MTS
  后的重新初始化或同步完成边界。
"""

from __future__ import annotations

import time

from . import hardware_master_slave_deterministic_sync_test as base
from ..capabilities import PlaybackState
from ..errors import DriverError
from ..sync_group import SyncGroup


# 当前实验室发现到的地址。板卡重新烧写后如果地址变化，以 discover_boards 结果为准。
MASTER_TARGET_IP = "169.254.21.60"       # 082 master
SLAVE_TARGET_IP = "169.254.214.189"      # 081 slave
TRIGGER_COUNT = 20
INTER_TRIGGER_S = 0.10


def _wait_prepared(device, label: str) -> None:
    """等待 ARM 后进入 PREPARED，避免只依据 UDP ACK 判断已经可触发。"""

    deadline = time.monotonic() + 5.0
    last = None
    while time.monotonic() < deadline:
        last = device.status(refresh=True)
        if last.state is PlaybackState.PREPARED:
            return
        time.sleep(0.02)
    actual = "unknown" if last is None else last.state.value
    raise AssertionError(f"{label} did not enter PREPARED, actual={actual}")


def _configure_and_upload(device, record, label: str) -> None:
    """重新上传一条有限波形；不改变同步 epoch。"""

    base._configure_and_upload(device, record, label)


def run() -> int:
    """执行一次 SYNC，然后连续触发固定次数。"""

    record = base._make_gaussian_record()
    master = base._new_device(MASTER_TARGET_IP)
    slave = base._new_device(SLAVE_TARGET_IP)
    try:
        master.connect()
        slave.connect()
        for device in (master, slave):
            try:
                device.abort_mute()
            except DriverError:
                pass
        time.sleep(0.5)

        master.require_external_sync()
        slave.require_external_sync()
        base._wait_rfdc_ready(master, "082 master")
        base._wait_rfdc_ready(slave, "081 slave")

        # 只执行一次 SYNC。后续循环禁止再次调用 group.sync()。
        group = SyncGroup(master, slave, timeout_s=5.0, poll_interval_s=0.01)
        alignment = group.sync(epoch=1, abort_before_sync=True)
        print(
            "一次 SYNC 完成："
            f"master_epoch={alignment.master_alignment_epoch}, "
            f"slave_epoch={alignment.slave_alignment_epoch}, "
            f"elapsed={alignment.elapsed_s:.3f}s"
        )

        for trigger_index in range(1, TRIGGER_COUNT + 1):
            # 每轮只重置播放器和重新上传数据，不重新执行 SYNC/MTS/NCO。
            if trigger_index > 1:
                master.abort_mute()
                slave.abort_mute()
                time.sleep(0.20)

            _configure_and_upload(master, record, "082 master")
            _configure_and_upload(slave, record, "081 slave")
            master.arm(channel_mask=base.CHANNEL_MASK)
            slave.arm(channel_mask=base.CHANNEL_MASK)
            _wait_prepared(master, "082 master")
            _wait_prepared(slave, "081 slave")

            master_before = master.status(refresh=True).capabilities
            slave_before = slave.status(refresh=True).capabilities
            master.trigger()
            base._wait_counter(
                master,
                "trigger_output_count",
                master_before.trigger_output_count,
                f"第 {trigger_index} 次 082 XS18 输出",
            )
            base._wait_counter(
                slave,
                "trigger_accepted_count",
                slave_before.trigger_accepted_count,
                f"第 {trigger_index} 次 081 XS19 接受",
            )
            print(
                f"[{trigger_index:02d}/{TRIGGER_COUNT}] "
                f"保持 SYNC epoch={alignment.master_alignment_epoch}; "
                "请在示波器上记录这一次主从包络相对延迟"
            )
            time.sleep(INTER_TRIGGER_S)

        print(
            f"PASS: 一次 SYNC 后完成 {TRIGGER_COUNT} 次 Trigger；"
            "没有在循环中再次执行 SYNC/MTS/NCO。"
        )
        print("最终请比较示波器记录的 20 次主从包络起点延迟。")
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
