"""250 MHz 主卡/从卡完整同步发波流程。

本脚本管理两块板卡：广播发现并分配 IP 后，主卡和从卡都设置为 external
模式，主卡通过 XS20 发一次 SYNC，等待两侧 MTS/NCO 对齐完成；随后两块板
各上传一次有限 CH1 波形并 ARM。之后每次调用主卡 ``trigger()``：

* 主卡本地播放一条波形，并由 XS18 输出物理 Trigger；
* 从卡通过 XS19 接受该 Trigger，播放同一条波形；
* 当前波形结束后 FPGA 自动重新预取并回到 PREPARED；
* 下一次 Trigger 不需要重新上传波形或 ARM。

上传/预取或上一条波形尚未重新 PREPARED 时到达的 Trigger 不会排队，脚本会
根据输入/接受计数差异报告过快事件。脚本不使用 ``loop=True``，因为这里需要
“一次 Trigger 对应一条波形”，而不是一次 Trigger 后无限循环。

运行前确认：两块板 XS17 接同一个 250 MHz 参考；主卡 XS20 -> 从卡 XS20；
主卡 XS18 -> 从卡 XS19；主机网卡已经配置 169.254.250.11/16。
"""

from __future__ import annotations

import time

from ..capabilities import PlaybackState
from ..errors import DriverError
from ..hardware_test_network import BoardNetworkAssignment
from ..sync_group import SyncGroup
from . import _common as common


EXPECTED_MASTER_ROLE = "master"
EXPECTED_SLAVE_ROLE = "slave"
TRIGGER_COUNT = 20
TRIGGER_INTERVAL_S = 0.020


def _wait_prepared(device, label: str) -> None:
    """等待播放器重新进入 PREPARED，确认可以接受下一次 Trigger。"""

    common.wait_state(device, PlaybackState.PREPARED, f"{label} PREPARED", timeout_s=10.0)


def run() -> int:
    """执行广播入网、一次 SYNC、一次上传和 20 次主卡 Trigger。"""

    master = None
    slave = None
    try:
        enrolled = common.enroll(
            [
                BoardNetworkAssignment(
                    label="主卡",
                    sync_role=EXPECTED_MASTER_ROLE,
                    ip=common.MASTER_TARGET_IP,
                    device_uid=common.MASTER_DEVICE_UID,
                    match_mac=common.MASTER_MATCH_MAC,
                    mac=common.MASTER_TARGET_MAC,
                    subnet_mask=common.TARGET_SUBNET_MASK,
                    gateway=common.TARGET_GATEWAY,
                ),
                BoardNetworkAssignment(
                    label="从卡",
                    sync_role=EXPECTED_SLAVE_ROLE,
                    ip=common.SLAVE_TARGET_IP,
                    device_uid=common.SLAVE_DEVICE_UID,
                    match_mac=common.SLAVE_MATCH_MAC,
                    mac=common.SLAVE_TARGET_MAC,
                    subnet_mask=common.TARGET_SUBNET_MASK,
                    gateway=common.TARGET_GATEWAY,
                ),
            ]
        )
        master = common.new_device(enrolled[EXPECTED_MASTER_ROLE])
        slave = common.new_device(enrolled[EXPECTED_SLAVE_ROLE])
        master_initial = common.show_status(master, "主卡初始")
        slave_initial = common.show_status(slave, "从卡初始")
        if master_initial.capabilities.sync_role != EXPECTED_MASTER_ROLE:
            raise AssertionError("发现的主卡不是 master bitstream")
        if slave_initial.capabilities.sync_role != EXPECTED_SLAVE_ROLE:
            raise AssertionError("发现的从卡不是 slave bitstream")
        common.wait_rfdc_ready(master, "主卡")
        common.wait_rfdc_ready(slave, "从卡")
        common.ensure_idle(master, "主卡")
        common.ensure_idle(slave, "从卡")

        # 主从都使用 external。此处不调用 bypass，确保 XS20 真正参与同步。
        master.require_external_sync()
        slave.require_external_sync()
        print("主卡/从卡均已设置为 external，开始一次严格 SYNC")
        group = SyncGroup(master, slave, timeout_s=8.0, poll_interval_s=0.01)
        alignment = group.sync(
            epoch=1, abort_before_sync=True
        )
        print(
            "SYNC 对齐完成："
            f"master_epoch={alignment.master_alignment_epoch}, "
            f"slave_epoch={alignment.slave_alignment_epoch}, "
            f"elapsed={alignment.elapsed_s:.3f}s"
        )

        record = common.make_gaussian_record()
        # SYNC 完成后才上传波形；上传期间物理 Trigger 不接受。
        common.configure_and_arm(master, record, label="主卡")
        common.configure_and_arm(slave, record, label="从卡")
        _wait_prepared(master, "主卡")
        _wait_prepared(slave, "从卡")

        master_caps = master.status(refresh=True).capabilities
        slave_caps = slave.status(refresh=True).capabilities
        for index in range(1, TRIGGER_COUNT + 1):
            # 每次 Trigger 之前都确认两块板的上一条有限波形已经重新准备好。
            _wait_prepared(master, "主卡")
            _wait_prepared(slave, "从卡")
            before_master = master.status(refresh=True).capabilities
            before_slave = slave.status(refresh=True).capabilities
            master.trigger()
            common.wait_counter(
                master,
                "trigger_output_count",
                before_master.trigger_output_count,
                f"第 {index} 次主卡 XS18 输出",
            )
            common.wait_counter(
                slave,
                "trigger_accepted_count",
                before_slave.trigger_accepted_count,
                f"第 {index} 次从卡 XS19 接受",
            )
            master_caps = master.status(refresh=True).capabilities
            slave_caps = slave.status(refresh=True).capabilities
            print(
                f"[{index:02d}/{TRIGGER_COUNT}] "
                f"主卡 accepted={master_caps.trigger_accepted_count}/"
                f"output={master_caps.trigger_output_count}，"
                f"从卡 input={slave_caps.trigger_input_count}/"
                f"accepted={slave_caps.trigger_accepted_count}"
            )
            if slave_caps.trigger_input_count > slave_caps.trigger_accepted_count:
                print("WARNING: 从卡存在未接受 Trigger；请增大 Trigger 间隔")
            time.sleep(TRIGGER_INTERVAL_S)

        print(
            f"PASS: 一次 SYNC 后完成 {TRIGGER_COUNT} 次主卡 Trigger；"
            "每次均由主卡 XS18 驱动从卡 XS19 播放一条有限波形。"
        )
        return 0
    except (DriverError, AssertionError) as error:
        print(f"FAIL: {type(error).__name__}: {error}")
        return 2
    finally:
        common.cleanup(slave, master)


if __name__ == "__main__":
    raise SystemExit(run())
