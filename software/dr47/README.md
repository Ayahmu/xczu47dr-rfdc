# 47DR Driver

开始实际联调前，请先阅读中文[驱动使用指南](../../docs/dr47_user_guide.md)，其中包含
安装、网络准备、板卡发现、波形播放、同步触发和验收预期。

完整 API 参考（函数签名、参数、返回值、CLI 和双板卡端到端示例）：
[`docs/dr47_api.md`](../../docs/dr47_api.md)。

驱动测试总览（包括四类正式发波入口、接线、预期状态和仿真测试边界）：
[`TESTING.md`](TESTING.md)。

Direct UDP driver for the XCZU47DR RFDC playback bitstream.  The package has
no web-server dependency and exposes `Dr47Device`, `SequenceGenerator`, and
`SimulatedDr47Device` through the `dr47` import name.

正式板级测试统一放在 `examples/` 子包中：

```bash
# 正常主卡 -> 从卡：XS20 SYNC + XS18 -> XS19 Trigger
PYTHONPATH=software python -m dr47.examples.hardware_master_slave_wave_test
# 主卡单卡：不调用 sync()，仅 UDP trigger() 本地发波
PYTHONPATH=software python -m dr47.examples.hardware_master_standalone_wave_test
# 从卡单卡：bypass_sync() 后仅 UDP trigger() 本地发波，XS20/XS18/XS19 均不参与
PYTHONPATH=software python -m dr47.examples.hardware_slave_bypass_software_trigger_test
# 从卡 external：等待 XS20 SYNC 后等待 XS19 外部 Trigger 或执行 XS18->XS19 回环
PYTHONPATH=software python -m dr47.examples.hardware_slave_external_trigger_test
```

这四个脚本是唯一维护的正式板级测试入口。每个脚本顶部集中放置发现地址、目标
IP、可选 `device_uid` 和可选 MAC，不使用网络命令行参数。`run()` 按照“广播发现
-> 角色/UID 选择 -> IP 配置并验证 -> 连接 -> 波形配置 -> 下载 -> ARM -> Trigger
-> 状态检查 -> 清理”顺序编排，并在 `finally` 中执行 `abort_mute()` 和 `close()`。
共享的波形转换位于 `waveforms.py`，共享的 Trigger 序列位于 `sequence.py`，板级
脚本不再充当驱动工具库。

10 MHz 与 250 MHz 工程使用同一套 Python 驱动。运行脚本前必须确认 XS17 输入频率
与已烧写 bitstream 的 HMC7044 时钟计划一致；驱动不会也不能在运行时改变该计划。

`record_duration_ns` and `delay_ns` have the same meaning as the web manual
waveform request. The finite pulse is placed at `delay_ns` inside an aligned,
zero-filled playback record. Keep padding after a Gaussian pulse; setting the
record length equal to the active pulse intentionally puts its final sample at
the playback-frame boundary and can produce a discontinuity at repetition.

At the public API boundary, NCO frequencies are GHz:

```python
device.set_xy_nco_frequency(1, 1.79)
device.apply_rfdc_config(nco_ghz={1: 1.79})
```

The packet encoder still converts these values to RFCTRL2 integer Hz because
that is the firmware wire format.  For RF carriers above the 400 MS/s complex
baseband Nyquist limit, upload a DC or low-frequency IQ envelope and use the
NCO for the carrier.

## Single-SYNC and Trigger API

The connector contract is fixed: XS20 is the dedicated SYNC link, XS18
(`TRIG_1`) is output-only Trigger, and XS19 (`TRIG_2`) is input-only Trigger.
In formal `external` mode a slave accepts XS19 edges only after one physical
XS20 rising edge. The same SYNC epoch then covers subsequent Trigger edges; a
Trigger must not be accompanied by another SYNC pulse.

```python
device.set_sync_role("slave")
device.set_sync_mode("external")
# Upload a sequence that waits for Trigger, configure RFDC/output, then:
device.arm(channel_mask=0x01)
# XS20 rising edge arrives externally. Every later XS19 rising edge plays once.
status = device.status().capabilities
assert status.sync_seen and status.sync_link_ready
```

For a single-board physical loopback test, wire `XS18 -> XS19`, select the
explicit test bypass, and emit the Trigger through the real output connector:

```python
device.bypass_sync()  # Explicit standalone permission; XS20 remains unseen.
device.arm(channel_mask=0x01)
device.emit_trigger()                  # XS18 -> cable -> XS19
```

`trigger()` is different: it is a local UDP software trigger and does not
drive XS18. `emit_trigger()` drives XS18 but does not directly start local
playback. Check `sync_seen`, `sync_link_ready`, `trigger_input_count`,
`trigger_accepted_count`, and `trigger_output_count` through
`device.status().capabilities` when commissioning the cable path.

## Switched multi-board enrollment

After programming a bitstream, boards boot with DNA-derived `169.254.x.y/16`
addresses. Put the host 10G interface on the same link-local network, then:

For a NetworkManager-managed Linux host, persist this host discovery address
once before using the workflow. Replace the connection name and interface with
the values from `nmcli connection show`; this adds an address and does not
remove existing addresses.

```bash
sudo nmcli connection modify "Wired connection 1" +ipv4.addresses "169.254.250.11/16"
sudo nmcli connection up "Wired connection 1"
ip address show dev enp225s0f1
```

The `169.254.0.0/16` direct route is created automatically. This persistent
setup avoids having to rerun `ip address replace` after reboot, network service
restart, or cable reconnection.

```bash
dr47-network prepare-interface --interface enp225s0f0 --source-ip 169.254.250.10/16
dr47-network discover --interface enp225s0f0 --source-ip 169.254.250.10 --json
dr47-network plan --interface enp225s0f0 --source-ip 169.254.250.10 \
  --ip-pool 10.50.0.101-10.50.0.120
```

Discovery is read-only. Assign a unique static address explicitly for each
`device_uid`; provisioning applies `NETWORK_APPLY`, restarts the board, and
verifies the new unicast address:

```bash
dr47-network provision --interface enp225s0f0 --source-ip 169.254.250.10 \
  --device-uid <UID> --ip 10.50.0.101 --mac 02:50:00:00:00:01
dr47-network status --interface enp225s0f0 --ip 10.50.0.101
```

Repeat this workflow after a bitstream reprogram. The workflow deliberately
does not use the legacy shared `192.168.254.254` bootstrap address. The switch
must pass broadcasts within the board VLAN; after provisioning, normal control
uses unicast IP addresses and UDP port 1234.
