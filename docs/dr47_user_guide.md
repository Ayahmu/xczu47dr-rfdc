# XCZU47DR 驱动使用指南

本文档面向需要通过 Python 驱动直接控制 XCZU47DR RFDC 板卡的使用者，说明安装、
主机与板卡准备、交换机网络发现、静态 IP 配置、波形播放、同步触发和验收方法。

完整函数签名、参数、返回值和异常说明请查阅 [API 参考](dr47_api.md)。

## 1. 驱动能力

`dr47` 是一个直接通过 UDP 控制 FPGA 中 RFCTRL2 服务的 Python 驱动，不依赖网页端。
它当前可以完成：

- 通过 10G 网卡连接单块或多块板卡；
- 在交换机后的链路上发现刚烧写 bitstream 的板卡，并为每块板卡配置静态 IP；
- 查询连接、网络、RFDC 和同步/触发状态；
- 配置 XY、Z、RO/IFOUT 通道的 RFDC NCO、增益和输出开关；
- 上传 IQ 或实数波形和播放序列，ARM 后软件或外部 Trigger 播放；
- 使用 XS20 做主从 SYNC，使用 XS18 到 XS19 做 Trigger。

当前驱动只覆盖播放链路。`ri/ifin`、DAQ、demod 和 pump 在当前 bitstream 中未实现；
调用相应能力会返回 `UnsupportedCapabilityError`。

## 2. 使用前准备

### 软件环境

主机需要 Linux、Python 3.10 或更高版本、可访问板卡的 10G 网卡，以及 `numpy`
（安装驱动时自动安装）。普通用户访问原始 UDP socket 通常需要 `CAP_NET_RAW`；
使用 `prepare-interface` 修改网卡地址需要 `sudo` 或 `CAP_NET_ADMIN`。

确认网卡和 NetworkManager 连接名：

```bash
ip -brief address
nmcli connection show
```

本文示例使用以下现场参数，使用时应替换为实际值：

```text
10G 网卡：enp225s0f1
NetworkManager 连接名：Wired connection 1
发现用主机地址：169.254.250.11/16
正式控制网段：10.50.0.0/24
正式主机地址：10.50.0.10/24
RFCTRL2 UDP 端口：1234
```

### 硬件和网络条件

- 板卡已烧写匹配的 bitstream，串口日志中 RFCTRL2 已启动。
- 上位机、交换机和板卡在同一专用二层 VLAN，且交换机允许该 VLAN 内广播。
- 板卡刚烧写后使用 DNA 派生的临时 `169.254.x.y/16` 地址，不能假定固定地址。
- 每块板卡的正式 IP 必须唯一；网络身份以 `device_uid` 为准，不能以 JTAG 序列号、
  交换机端口或 `ttyUSB` 名称判断。
- 两板同步时，使用 `master XS20 -> slave XS20` 传输一条 SYNC，使用
  `master XS18 -> slave XS19` 传输后续 Trigger。

## 3. 安装

在仓库根目录执行：

```bash
cd software/dr47
python -m pip install .
```

安装完成后验证导入和 CLI：

```bash
python -c 'import dr47; print(dr47.Dr47Device)'
dr47-network --help
```

开发期间也可以不安装，从仓库根目录直接运行：

```bash
PYTHONPATH=software python -c 'from dr47 import Dr47Device; print(Dr47Device)'
```

## 4. 首次部署：配置主机发现地址

发现刚烧写的板卡前，主机 10G 网卡必须拥有同一 `169.254.0.0/16` 网段的地址。
建议将地址保存到 NetworkManager；只需要配置一次，之后重启、网线重插或网络服务
重启时都能自动恢复。

```bash
# 查看实际连接名；示例中的网卡与连接名必须替换为现场值。
nmcli connection show

# 给现有 10G 连接额外增加发现地址，不会删除已有正式 IP。
sudo nmcli connection modify "Wired connection 1" \
  +ipv4.addresses "169.254.250.11/16"
sudo nmcli connection up "Wired connection 1"

# 确认地址已经存在；169.254.0.0/16 直连路由会自动生成。
ip address show dev enp225s0f1
ip route get 169.254.34.120
```

预期结果：第一条查询能看到 `169.254.250.11/16`；第二条查询应显示访问
`169.254.x.y` 通过 `enp225s0f1`。`nmcli connection up` 可能令网卡短暂重连，
应在不影响当前控制任务时执行。

也可以临时配置该地址：

```bash
sudo dr47-network prepare-interface \
  --interface enp225s0f1 \
  --source-ip 169.254.250.11/16
```

该命令适合临时联调，但它不替代上面的持久化设置。

## 5. 重新烧写后的首次入网

每次重新烧写 bitstream 后，按下面流程重新发现和分配地址。驱动不使用历史的
共享 bootstrap IP，也不会默认写入任何正式 IP。

### 5.1 发现全部板卡

```bash
dr47-network discover \
  --interface enp225s0f1 \
  --source-ip 169.254.250.11 \
  --json
```

预期结果：输出 JSON 数组，每块板卡至少包含 `device_uid`、`current_ip`、`mac` 和
`profile`。检查每个 `device_uid` 和 MAC 都不重复，并根据现场记录确认每块板卡的
物理身份与主/从角色。此命令只读，不会改动板卡。

### 5.2 生成地址分配预览

```bash
dr47-network plan \
  --interface enp225s0f1 \
  --source-ip 169.254.250.11 \
  --ip-pool 10.50.0.101-10.50.0.120
```

预期结果：显示 `device_uid -> proposed IP`。这仅用于预览，不会配置任何板卡。
执行下一步前，应记录并确认需要给每个 UID 分配的正式 IP。

### 5.3 配置一块板卡并验证

以下命令将指定 UID 的板卡配置为 `10.50.0.101`，并在重启网络后验证返回的是同一
个 `device_uid`：

```bash
dr47-network provision \
  --interface enp225s0f1 \
  --source-ip 169.254.250.11 \
  --device-uid 47d0xxxxxxxxxxxx \
  --ip 10.50.0.101 \
  --mac 02:50:00:00:00:01
```

对每块板卡重复该操作，必须使用不同 IP 与 MAC。随后给主机同一 10G 网卡添加正式
控制网段地址：

```bash
sudo nmcli connection modify "Wired connection 1" \
  +ipv4.addresses "10.50.0.10/24"
sudo nmcli connection up "Wired connection 1"

dr47-network status --interface enp225s0f1 --ip 10.50.0.101
```

预期结果：`status` 能返回板卡状态。若新 IP 无法连接，优先检查主机是否有
`10.50.0.10/24`、板卡 IP/MAC 是否重复、交换机 VLAN 是否一致。

## 6. 最小单板控制示例

此示例连接一块已配置正式 IP 的板卡，查询状态，设置 CH1 的 NCO 和输出开关，
然后关闭连接。它不会上传或触发波形。

```python
from dr47 import Dr47Device

# 指定板卡正式 IP、10G 网卡和该网卡上的正式源 IP。
with Dr47Device(
    ip="10.50.0.101",
    port=1234,
    udp_interface="enp225s0f1",
    udp_source_ip="10.50.0.10",
    timeout_s=2.0,
    retries=2,
) as device:
    # 进入上下文时执行 HELLO/STATUS；失败会抛出 DriverError 子类。
    capability = device.status().capabilities
    print(capability)

    # CH1 是 xy 通道 1。高层 NCO 单位为 GHz。
    device.set_xy_nco_frequency(1, 1.0)
    device.set_qc_on_off("xy", 1, "on")

    # 停止并静音整块板卡，避免上次测试的播放状态残留。
    device.abort_mute()
```

预期结果：程序退出码为 0，且输出状态中 RFCTRL2 在线、目标通道具有播放能力。
如出现超时，先用 `dr47-network status` 验证 IP、网卡和源地址。

## 7. 发射一个波形

驱动中提供了可直接编辑的实板测试脚本：

```bash
PYTHONPATH=software python -m dr47.hardware_wave_test
```

打开 `software/dr47/hardware_wave_test.py`，先修改 `HardwareWaveTestConfig` 的
网络字段，再选择 `ACTIVE_EXAMPLE`：

```python
ACTIVE_EXAMPLE = "one_shot_1ghz_sine"
```

可选示例包括：

| 示例 | 预期输出 | 使用场景 |
| --- | --- | --- |
| `one_shot_1ghz_sine` | CH1 约 100 ns、1 GHz 的单次 IQ 包络调制载波 | 基本输出检查 |
| `one_shot_1p79ghz_gaussian_xy` | CH1 约 60 ns、1.79 GHz 高斯包络脉冲 | 脉冲与 NCO 检查 |
| `continuous_2ghz_sine` | CH1 持续 2 GHz 输出，直到脚本停止/静音 | 连续波检查 |
| `triggered_1p5ghz_gaussian_xy` | CH1 等待 Trigger 后每次播放一次 120 ns 脉冲 | Trigger 链路检查 |

频率规则很重要：上传到 DDR 的 IQ 基带采样率为 400 MS/s，因此基带频率必须在
`-0.2` 到 `+0.2 GHz`；例如 1 GHz 或 1.79 GHz 的射频载波由 `NCO` 生成，上传的
波形通常使用 DC 或低频包络。高层 API 的频率参数统一为 GHz。

运行一键测试前，确认示波器已接到要测试的 DAC 输出。预期结果是脚本打印连接、
配置和播放状态；示波器频率应接近 `frequency_ghz`，而不是基带包络频率。

## 8. 外部 SYNC 和 Trigger

三个 SMP 接口的职责固定：

| 接口 | 方向与含义 | 驱动调用 |
| --- | --- | --- |
| XS20 | 专用 SYNC；主卡输出、从卡接收 | 主卡 `sync()` |
| XS18 (`TRIG_1`) | Trigger 输出 | `emit_trigger()` |
| XS19 (`TRIG_2`) | Trigger 输入 | 外部物理上升沿 |

正式双卡操作顺序如下：

1. 接线：主卡 XS20 到从卡 XS20，主卡 XS18 到从卡 XS19。
2. 两块板卡均设置 `set_sync_mode("external")`；从卡设置
   `set_sync_role("slave")`，主卡设置 `set_sync_role("master")`。
3. 主卡调用一次 `sync()`，从卡的 `sync_seen` 与 `sync_link_ready` 应变为真。
4. 向从卡上传含 Trigger-wait 的序列并调用 `arm()`。
5. 每需要播放一次，主卡调用 `emit_trigger()`；该脉冲通过 XS18/XS19 触发从卡。

`trigger()` 是软件本地触发，不会驱动 XS18；`emit_trigger()` 只输出 XS18 脉冲，
不会直接播放本机波形。不要把每次 Trigger 前再发送一次 SYNC，当前同步周期中一条
有效 XS20 上升沿即可。

单板测试可将 XS18 接到 XS19，使用 `set_sync_mode("self_test")` 绕过 XS20。
这是 Trigger 物理回环测试，不是两板定时同步，不能用于正式同步实验。

## 9. 从头到尾：两板配置、同步和触发

下例假设两块已烧写板卡通过同一交换机连接，且已根据第 5 节获得正式 IP。
代码明确以 UID 映射角色，避免使用网口或 JTAG 序列号作为身份。

```python
import numpy as np

from dr47 import Dr47Device
from dr47.hardware_wave_test import make_trigger_sequence

INTERFACE = "enp225s0f1"
HOST_IP = "10.50.0.10"
MASTER_IP = "10.50.0.101"
SLAVE_IP = "10.50.0.102"

# 400 MS/s 复 IQ 基带中的 100 ns DC 包络：40 个复样点。
# 高 RF 载波由后面的 NCO 产生，故此处保持低频/直流包络。
sample_count = 40
iq = np.zeros((sample_count, 2), dtype="<i2")
iq[:, 0] = 12000
sequence = make_trigger_sequence(sample_count)

with Dr47Device(MASTER_IP, udp_interface=INTERFACE, udp_source_ip=HOST_IP) as master, \
     Dr47Device(SLAVE_IP, udp_interface=INTERFACE, udp_source_ip=HOST_IP) as slave:
    # 1. 设定物理接口角色和正式外部同步模式。
    master.set_sync_role("master")
    master.set_sync_mode("external")
    slave.set_sync_role("slave")
    slave.set_sync_mode("external")

    # 2. 主卡从 XS20 发出一次同步边沿，从卡因此打开 Trigger 接收门。
    master.sync()
    sync_status = slave.status().capabilities
    if not (sync_status.sync_seen and sync_status.sync_link_ready):
        raise RuntimeError("从卡尚未观察到 XS20 SYNC；检查 XS20 连线和角色配置")

    # 3. 从卡上传一个“每次 Trigger 后播放一次”的 CH1 IQ 波形和序列。
    slave.download_qc_wave_seq("xy", 1, iq, sequence)
    slave.set_xy_nco_frequency(1, 1.0)  # 单位 GHz。
    slave.set_qc_on_off("xy", 1, "on")

    # 4. ARM 后，从卡等待 XS19 的外部 Trigger，而不是立刻输出。
    slave.arm(channel_mask=0x01)

    # 5. 主卡在 XS18 输出一个物理 Trigger；它沿电缆到从卡 XS19 后播放一次。
    master.emit_trigger()

    # 6. 读取计数器确认从卡已接收并接受该 Trigger。
    trigger_status = slave.status().capabilities
    if trigger_status.trigger_accepted_count < 1:
        raise RuntimeError("从卡未接受 Trigger；检查 XS18 -> XS19 连线和 ARM 状态")

    # 7. 结束实验时静音两块板，避免持续保持射频输出。
    slave.abort_mute()
    master.abort_mute()
```

预期效果：从卡在主卡 `sync()` 后报告 `sync_seen=True` 和
`sync_link_ready=True`；每执行一次 `master.emit_trigger()`，从卡的
`trigger_input_count`、`trigger_accepted_count` 应递增一次，示波器应观察到一段
约 100 ns 的 1 GHz 输出脉冲。

## 10. 日常检查和常见问题

### 连接超时或找不到板卡

按顺序检查：

1. `ip address show dev enp225s0f1` 中是否存在正确的发现或正式控制地址。
2. `dr47-network discover` 是否能收到板卡；不能收到时检查 bitstream、串口、
   10G 链路和交换机广播/VLAN。
3. 使用 `dr47-network status --interface enp225s0f1 --ip <板卡IP>` 验证单播。
4. Python 中明确设置 `udp_interface` 和 `udp_source_ip`，避免系统选择错误网卡。

### 烧写后正式 IP 失效

这是当前设计的预期行为：网络配置不写入非易失存储。重新烧写后需要重复
“发现 -> 确认 UID -> provision -> 验证”流程。主机的 `169.254.250.11/16` 地址
应持久保存，因此不需要每次手工重新添加。

### 从卡一直等待 SYNC

确认从卡使用的是 slave bitstream，角色为 `slave`，模式为 `external`，并检查
XS20 连线方向和信号质量。只有实际观察到一次 XS20 上升沿后，从卡才会接受 XS19
Trigger；`self_test` 只能用于单板 XS18 到 XS19 回环验证。

### 频率与预期不符

确认把射频目标频率传给 `set_xy_nco_frequency()` 或
`apply_rfdc_config(nco_ghz=...)`，且单位是 GHz。不要把高于 0.2 GHz 的射频频率
直接生成在 400 MS/s 的基带 IQ 数据中；应使用 NCO 载波和低频 IQ 包络。

## 11. 参考资料

- [API 参考](dr47_api.md)：完整函数签名、参数、返回值、异常和 CLI 参数。
- [驱动 README](../software/dr47/README.md)：简洁英文概览和实板冒烟测试入口。
- [波形板级测试计划](rfdc_waveform_board_test_plan.md)：示波器和硬件验收步骤。
