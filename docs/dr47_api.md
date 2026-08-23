# XCZU47DR 驱动 API 文档

本文档对应当前仓库中的 `software/dr47` 驱动包（版本 `0.1.0`）。驱动通过
UDP 控制 FPGA PL 中的 RFCTRL2 服务，支持单板控制，也支持通过 10G 交换机
发现和配置多块板卡。

## 1. 安装与基本约定

### 安装

```bash
cd software/dr47
python -m pip install .
```

开发环境也可以直接使用源码：

```bash
PYTHONPATH=software python your_script.py
```

### 网络参数

| 参数 | 当前默认值 | 说明 |
| --- | --- | --- |
| 板卡 UDP 端口 | `1234` | RFCTRL2 控制和波形数据使用的 UDP 端口 |
| 初始板卡地址 | `169.254.x.y/16` | FPGA 根据 DNA 生成，重新烧写后用于首次发现 |
| 首次发现广播 | `169.254.255.255` | 同一 VLAN 中的定向广播地址 |
| 波形布局 | `interleaved_512b` | 当前 PL 支持的 8 通道交错 DDR 布局 |
| RFDC NCO 单位 | GHz | 高层 API 使用 GHz；底层 RFCTRL2 使用整数 Hz |
| 相位单位 | degree | `phase_deg` 为 RFDC 数字 NCO 相位角 |
| DAC 输出电流单位 | mA | `output_current_ma` 或 `set_gain` 的物理单位 |

`udp_interface` 用于指定上位机实际的 10G 网卡，避免 Linux 从错误的同网段
网卡发包。Linux 下使用它通常需要 `CAP_NET_RAW`。首次配置主机临时地址时，
`prepare_interface()` 需要 `CAP_NET_ADMIN`。

板卡身份以 `device_uid` 为准，不要用交换机端口、JTAG 序列号或 `/dev/ttyUSBx`
作为网络身份。

### 首次部署：持久配置发现地址

每次重新烧写 bitstream 后，板卡会回到 DNA 派生的 `169.254.x.y/16` 临时
地址，驱动必须从同一网段的主机地址发起广播发现。**在首次部署前，使用者需要
为连接板卡/交换机的 10G 网卡配置一个 `169.254.x.y/16` 地址。**

`dr47-network prepare-interface` 和 `prepare_interface()` 只写入当前运行的 Linux
网络状态；重启主机、NetworkManager 重连或网线重插后可能丢失。使用
NetworkManager 的 Linux 主机建议执行一次以下命令，将发现地址持久保存到网卡
连接配置中。这里的网卡和连接名应替换为现场实际值：

```bash
# 先查看连接名；示例中的实际连接名为 "Wired connection 1"。
nmcli connection show

# 只需首次配置时执行一次。为现有 10G 连接额外增加发现地址，不会删除已有 IP。
sudo nmcli connection modify "Wired connection 1" \
  +ipv4.addresses "169.254.250.11/16"
sudo nmcli connection up "Wired connection 1"

# 验证地址和自动生成的直连路由。
ip address show dev enp225s0f1
ip route get 169.254.34.120
```

上例适用于主机 10G 网卡 `enp225s0f1`。它会保留该连接已有的
`192.168.x.x` 等地址，并自动建立到 `169.254.0.0/16` 的直连路由，通常无需
再手工执行 `ip route replace`。执行 `nmcli connection up` 时网卡可能短暂重连；
请在不影响当前控制任务的时机进行。若该连接由 DHCP 或用于非板卡网络，建议为
专用 10G 口单独建立静态 NetworkManager 连接，而不要修改日常办公网络。

## 2. 导入与核心对象

```python
from dr47 import (
    Dr47Device,
    connect,
    discover_boards,
    provision_board,
    connect_discovered,
)
```

### `Dr47Device`

一个 `Dr47Device` 对象对应一块板卡。创建对象不会立即访问网络；调用
`connect()` 或使用 `connect()` 工厂函数后才发送 RFCTRL2 请求。

```python
Dr47Device(
    ip="10.50.0.101",
    port=1234,
    timeout_s=5.0,
    udp_interface="enp225s0f0",
    udp_source_ip="10.50.0.10",
    retries=2,
    batch_mode=False,
    slot=None,
    transport=None,
    **legacy_options,
)
```

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| `ip` | `str` | 板卡当前可访问的 IPv4 地址 |
| `port` | `int` | UDP 端口，当前通常为 `1234` |
| `timeout_s` | `float` | 单次 UDP 等待超时，单位秒 |
| `udp_interface` | `str` | 发送所用网卡名；为空时交给系统路由选择 |
| `udp_source_ip` | `str` | UDP socket 绑定的源 IPv4；为空时由系统选择 |
| `retries` | `int` | 可确认 RFCTRL2 请求的重试次数 |
| `batch_mode` | `bool` | `True` 时暂存 RFDC/增益修改，之后由 `commit()` 一次提交 |
| `slot` | `int \| None` | 兼容旧 ez-Q 脚本；当前 UDP 驱动不使用它 |
| `transport` | object | 可注入自定义传输对象，主要用于测试 |
| `legacy_options` | 任意 | 旧脚本参数会保留但不参与当前 UDP 硬件控制 |

属性：

| 属性 | 返回值 | 说明 |
| --- | --- | --- |
| `device.capabilities` | `DeviceCapabilities` | 最近一次 HELLO/STATUS 得到的能力和状态缓存 |
| `device.connected` | `bool` | 当前对象是否已连接且未关闭 |
| `device.transport` | `UdpTransport` | 实际使用的 UDP 传输对象，访问时按需创建 |

### `connect(*args, **kwargs) -> Dr47Device`

创建 `Dr47Device`、执行 `device.connect()` 并返回已经连接的对象。

```python
from dr47 import connect

device = connect(
    ip="10.50.0.101",
    udp_interface="enp225s0f0",
    udp_source_ip="10.50.0.10",
)
try:
    print(device.status())
finally:
    device.close()
```

### `connect()` / `close()` / 上下文管理器

```python
device.connect()       # 发送 HELLO 和 STATUS，成功返回 0
device.close()         # 关闭 socket；返回 None

with Dr47Device(ip="10.50.0.101") as device:
    device.status()
```

连接失败、协议版本不匹配、板卡忙或 RFDC 未就绪时会抛出驱动异常，见第
9 节。`close()` 可以重复调用。

## 3. 多板卡首次入网 API

推荐流程是：

```text
prepare_interface
    -> discover_boards
    -> 用户确认 device_uid 与 IP 映射
    -> provision_board
    -> 使用正式 IP 创建 Dr47Device
```

### `prepare_interface(interface, source_cidr) -> None`

显式配置上位机 10G 网卡。该函数会执行 Linux `ip link` 和 `ip address`
命令，因此会修改主机网络配置。

```python
from dr47 import prepare_interface

prepare_interface("enp225s0f0", "169.254.250.10/16")
```

参数：

- `interface`：上位机 10G 网卡名。
- `source_cidr`：主机临时地址，必须包含前缀，首次发现应使用
  `169.254.250.10/16`。

返回 `None`。网卡不存在、权限不足或 `ip` 命令失败时抛出
`ConnectionError`。

### `discover_boards(...) -> list[DiscoveredBoard]`

向广播地址发送 RFCTRL2 `NETWORK_GET`，收集超时时间内所有板卡的回复，并按
`device_uid` 去重。该函数是只读操作，不会修改任何板卡网络配置。

```python
boards = discover_boards(
    interface="enp225s0f0",
    source_ip="169.254.250.10",
    source_cidr="169.254.250.10/16",
    broadcast_ip="169.254.255.255",
    port=1234,
    timeout_s=1.0,
    rounds=3,
)
```

| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `interface` | `str` | 必填 | 绑定的主机 10G 网卡 |
| `source_ip` | `str` | 必填 | 已配置在主机网卡上的源地址 |
| `source_cidr` | `str` | `169.254.250.10/16` | 必须与 `source_ip` 相同且为 `/16` |
| `broadcast_ip` | `str` | `169.254.255.255` | 发现广播地址 |
| `port` | `int` | `1234` | RFCTRL2 UDP 端口 |
| `timeout_s` | `float` | `1.0` | 每轮收集回复的时间 |
| `rounds` | `int` | `3` | 广播轮数，用于提高丢包环境下的发现概率 |

返回 `list[DiscoveredBoard]`。没有任何有效回复时抛出 `DiscoveryError`。

### `DiscoveredBoard`

不可变的数据对象，表示一次发现得到的板卡。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `device_uid` | `str` | FPGA DNA 派生的永久身份，首要识别字段 |
| `current_ip` | `str` | 发现时板卡正在使用的 IP |
| `current_mac` | `str` | 发现时板卡正在使用的 MAC |
| `build_profile` | `str` | 构建 profile，例如 `custom_xczu47dr` |
| `revision` | `int` | 当前网络配置 revision |
| `port` | `int` | 板卡当前 UDP 端口 |
| `subnet_mask` | `str` | 板卡当前掩码 |
| `gateway` | `str` | 板卡当前网关 |
| `response_address` | `str` | 回复 UDP 包的源 IP |
| `interface` | `str` | 发现使用的主机网卡 |
| `source_ip` | `str` | 发现使用的主机源 IP |

`board.ip` 是 `current_ip` 的简写；`board.as_dict()` 返回可 JSON 序列化的字典。

### `parse_ip_pool(value) -> list[str]`

解析同一个 `/24` 子网内的闭区间地址池：

```python
parse_ip_pool("10.50.0.101-10.50.0.120")
# ["10.50.0.101", ..., "10.50.0.120"]
```

跨越不同 `/24`、起点大于终点或格式错误时抛出 `ParameterRangeError`。

### `provision_board(...) -> ProvisionedBoard`

为一块已发现板卡配置正式静态 IP/MAC，并验证切换结果。函数内部顺序为：

```text
NETWORK_APPLY（旧 IP）
    -> 等待确认
NETWORK_RESTART（旧 IP）
    -> 板卡切换 IP/MAC 并清理 ARP
NETWORK_GET（新 IP）
    -> 校验返回 device_uid
```

```python
result = provision_board(
    board,
    ip="10.50.0.101",
    mac="02:50:00:00:00:01",
    subnet_mask="255.255.255.0",
    gateway="0.0.0.0",
    port=1234,
    revision=None,
    known_boards=boards,
    reject_unverified_conflict=False,
)
```

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| `board` | `DiscoveredBoard` | 要配置的发现结果 |
| `ip` | `str` | 新的正式 IPv4 地址，必填 |
| `mac` | `str \| None` | 新 MAC；为空时沿用发现到的 MAC |
| `subnet_mask` | `str` | 新掩码，默认 `/24` 的 `255.255.255.0` |
| `gateway` | `str` | 新网关，默认 `0.0.0.0` |
| `port` | `int` | 新 UDP 端口 |
| `revision` | `int \| None` | 新 revision；为空时使用旧 revision 加一 |
| `known_boards` | iterable | 用于检查本次发现结果中的 IP/MAC 冲突 |
| `reject_unverified_conflict` | `bool` | `True` 时要求主机安装 `arping` 并完成冲突检查 |

函数会在 `arping` 可用时执行主机侧 IP 冲突探测。默认情况下没有 `arping`
只是不阻止配置；若需要严格安全策略，设置 `reject_unverified_conflict=True`。

返回 `ProvisionedBoard`，其中 `verified=True` 表示新 IP 已返回预期的
`device_uid`。配置失败会抛出 `ProvisionError`，并明确指出是
`NETWORK_APPLY`、`NETWORK_RESTART`、新 IP 无响应、UID 不匹配还是地址冲突。

### `ProvisionedBoard`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `device_uid` | `str` | 已验证的板卡身份 |
| `previous_ip` | `str` | 配置前 IP |
| `ip` | `str` | 配置后的正式 IP |
| `mac` | `str` | 配置后的 MAC |
| `subnet_mask` | `str` | 配置后的掩码 |
| `gateway` | `str` | 配置后的网关 |
| `port` | `int` | 配置后的端口 |
| `revision` | `int` | 配置后的 revision |
| `build_profile` | `str` | 板卡构建 profile |
| `verified` | `bool` | 是否已通过新 IP 回读验证 |

### `connect_discovered(board, timeout_s=5.0, retries=2) -> Dr47Device`

使用 `DiscoveredBoard` 的当前 IP、端口、网卡和源 IP 创建并连接单板对象，
并检查连接到的 `device_uid` 是否一致。注意：如果板卡已经执行
`provision_board()`，应使用返回结果中的新 IP 创建 `Dr47Device`；原来的
`DiscoveredBoard.current_ip` 仍是旧 IP。

## 4. 单板状态、RFDC 与播放 API

### 状态与连接

#### `status(refresh=True) -> DeviceStatus`

返回板卡状态。`refresh=True`（默认）会发送一次 STATUS；`False` 只返回本地
缓存，不产生网络请求。

`DeviceStatus` 字段：`connected`、`ip`、`port`、`state`、`capabilities`、
`message`、`raw`。`status.online` 是 `connected` 的简写。

`DeviceCapabilities` 常用字段：

| 字段 | 说明 |
| --- | --- |
| `device_uid` | 永久设备身份 |
| `build_profile` | FPGA 构建 profile |
| `capability_bits` | RFCTRL2 能力位，可用 `has(bit)` 检查 |
| `rfdc_ready` | RFDC 是否就绪 |
| `dac_mts_ready` / `dac_mts_failed` | DAC MTS 状态 |
| `nco_sync_ready` | NCO 同步状态 |
| `sync_role` / `sync_mode` | 当前同步角色和模式 |
| `sync_seen` / `sync_link_ready` | 外部同步链路状态 |
| `trigger_input_count` | 收到的 Trigger 数 |
| `trigger_accepted_count` | 被接受的 Trigger 数 |
| `trigger_output_count` | 输出 Trigger 数 |
| `playback_state` | `PlaybackState` 枚举 |
| `config_valid_mask` | 已配置的 RFDC 通道位图 |
| `rfdc_readback` | RFDC 通道回读元组 |

#### `capabilities -> DeviceCapabilities`

读取最近一次 HELLO/STATUS 缓存，不主动发包。

### RFDC 配置

#### `apply_rfdc_config(nco_ghz=None, nyquist_zone=None, phase_deg=None, output_current_ma=None, revision=None, channel_mask=0xFF) -> dict`

批量配置最多 8 个 DAC 通道并回读结果。所有 mapping/sequence 都按物理
`CH1..CH8` 解释：mapping 的 key 可以是整数 `1` 或字符串 `"ch1"`；sequence
必须正好包含 8 个元素。

```python
readback = device.apply_rfdc_config(
    nco_ghz={1: 1.0, 2: 1.0},
    nyquist_zone={1: 1, 2: 1},
    phase_deg={1: 0.0, 2: 90.0},
    output_current_ma={1: 20.0, 2: 20.0},
    revision=1,
    channel_mask=0b00000011,
)
```

返回包含 `revision`、`applied_mask`、`error_mask`、`config_valid_mask`、
`failure_stage`、`failure_address`、`axi_response`、`state_flags` 和
`channels` 的字典。每个 `channels` 元素包含 NCO、相位、输出电流、状态和
硬件回读字。

RFDC NCO 范围为 `-3.2 .. +3.2 GHz`。当前项目 DAC 采样率为 `6.4 GSPS`，
具体模拟输出频率还要结合 Nyquist zone。

#### `set_xy_nco_frequency(channel, frequency_ghz, slot=None) -> int`

设置 XY 逻辑通道 `1..4` 对应 CH1..CH4 的 NCO。单位 GHz。非 batch 模式下
会立即提交该物理通道；成功返回 `0`。

#### `set_gain(channel_type, channel, gain=1.0, gain_type="norm", slot=None) -> int`

设置 DAC 输出电流。当前只支持 `gain_type="norm"`，`gain` 范围 `0..1`。
`xy` 映射 CH1..CH4，`z` 映射 CH5..CH6。成功返回 `0`。

当前电流范围：XY/RO 为 `2.25..40.5 mA`，Z 为 `6.4..32.0 mA`。

#### `commit() -> int`

只在 `batch_mode=True` 时提交暂存的 RFDC/NCO/增益修改；成功返回 `0`。

### 通道开关、波形和播放

#### `set_qc_on_off(channel_type, channel, on_off="on", slot=None) -> int`

设置 XY 或 Z 通道的播放使能。`channel_type` 支持 `xy`、`z`；`on_off`
必须为 `on` 或 `off`。修改的是本地通道 mask，成功返回 `0`。

#### `set_qr_on_off(gen_type, channel, on_off="on", slot=None) -> int`

设置 RO/QR 输出通道，RO/IFOUT 映射 CH7..CH8。`ri`/`ifin` 属于 ADC 输入，
当前 bitstream 不支持，会抛出 `UnsupportedCapabilityError`。

#### `upload_waveforms(channel_waves, channel_sequences=None, *, wave_formats=None, layout="interleaved_512b", base_addr=0, auto_start=True, loop=False, packet_pause_s=1e-5, packet_burst=8) -> dict`

上传一个或多个物理通道的波形，并生成 PL 播放指令。

| 参数 | 说明 |
| --- | --- |
| `channel_waves` | `{physical_channel: wave}`，通道范围 1..8 |
| `channel_sequences` | 可选的 `{physical_channel: ezq_sequence}` |
| `wave_formats` | 每个通道的格式：`iq_matrix`、`packed_iq`、`interleaved_iq`、`z`/`real` |
| `layout` | 当前必须为 `interleaved_512b` |
| `base_addr` | DDR 起始地址，必须满足硬件对齐要求 |
| `auto_start` | 没有 Trigger 序列时是否让 END 立即开始 |
| `loop` | 是否循环播放 |
| `packet_pause_s` | 每 `packet_burst` 个包后的暂停时间 |
| `packet_burst` | 每批发送的包数；用于降低 PL UDP RX FIFO 丢包概率 |

返回字典包括 `packet_count`、`channels`、`bytes_per_channel`、
`wait_for_trigger`、`loop` 和实际 `commands`。

当前推荐的波形格式是小端 IQ 交错 int16：`I0,Q0,I1,Q1,...`。二维矩阵可以
是形状 `(2, N)` 或 `(N, 2)`。

#### `arm(channel_mask=None, run_id=None) -> int`

准备播放但不立即输出。`channel_mask=None` 时使用已经打开的通道；如果没有
显式设置 mask，则默认使用 `0xFF`。成功返回 `0`，并将状态更新为 `ARMED`。

#### `trigger() -> int`

通过 UDP 发送本地播放 Trigger，成功返回 `0`，状态变为 `RUNNING`。它是本机
软件触发，不会在 XS18 上输出外部 Trigger。

#### `abort_mute() -> int`

停止/静音整板播放，状态回到 `IDLE`，成功返回 `0`。

#### 兼容上传和底层指令函数

| 函数 | 参数 | 功能与返回值 |
| --- | --- | --- |
| `download_qc_wave_seq(channel_type, channel, wave, seq, slot=None, **kwargs) -> int` | `channel_type` 为 `xy`/`z`，逻辑通道和波形/序列 | 映射到物理 CH 并上传带序列波形；成功返回 `0` |
| `download_qr_wave_seq(gen_type, channel, wave, seq, slot=None, **kwargs) -> int` | `gen_type` 为 `ro`/`ifout` 等输出类型 | 上传 QR/RO 输出序列；成功返回 `0` |
| `send_instructions(commands) -> int` | 四元组/五元组指令列表 | 直接发送 WAVEINS0 指令包；成功返回 `0` |
| `upload_waveform_udp(data_int16, ddr_addr, dump_path="", dump_style="hexdump")` | int16 波形和对齐的 DDR 地址 | 直接发送 DDR 写包；返回发送的数据包数量 |

这组函数主要用于兼容旧 ez-Q 脚本。新程序优先使用
`upload_waveforms()`，因为它会统一处理格式转换、交错 DDR 布局、指令和
发送节流。

#### `run_circuit(command=1, slot=None) -> int`

兼容旧 ez-Q 调用。当前只支持 `command=1`，其行为是必要时 ARM，然后执行
本地 `trigger()`。成功返回 `0`。

### 单 SYNC、外部 Trigger 与自测试旁路

物理连接由用户完成，三个 SMP 端口具有固定职责：

| 端口 | 固定职责 | 可由 API 主动驱动 |
| --- | --- | --- |
| XS20 | 专用 SYNC。master 输出、slave 输入。 | `sync()` 仅用于 external-mode master |
| XS18 (`TRIG_1`) | 外部 Trigger 输出。 | `emit_trigger()` |
| XS19 (`TRIG_2`) | 外部 Trigger 输入。 | 否，只能由物理上升沿驱动 |

正式外部模式的从板连接如下：

```text
外部 SYNC 源 / 主板 XS20 ----> 从板 XS20
外部 Trigger 源 / 主板 XS18 -> 从板 XS19
```

`external` 模式要求从板先在 XS20 接收到**一次**真实 SYNC 上升沿。收到该
单个脉冲后，XS19 的每个上升沿都可以触发一次已经 ARM 的、包含 Trigger-wait
指令的播放序列。SYNC 不是每次播放的 Trigger，也不应在每次 Trigger 前重复
发送。通过 `status().capabilities.sync_seen` 和 `sync_link_ready` 检查门控是否
已经打开。

单板物理回环测试连接如下：

```text
本板 XS18 ---- SMA-to-SMP cable ----> 本板 XS19
XS20 断开
```

该测试必须使用 `bypass`，它是明确的运行时旁路：跳过“必须先收到 XS20”
门控，但不生成、不模拟，也不证明外部同步。不要将此模式用于跨板同步或时序
对齐实验。

#### `set_sync_role(role) -> int`

`role` 必须为 `"master"` 或 `"slave"`。该方法只验证所烧写 bitstream 的
固定角色，不能在运行时改变 XS20 电气方向；请求另一角色会抛出
`SynchronizationError`，必须改烧对应的主卡或从卡 bitstream。
成功返回 `0`。

#### `set_sync_mode(mode) -> int`

`mode` 支持：

- `"external"`：正式外部同步。slave 在真实 XS20 单 SYNC 上升沿之前屏蔽
  XS19 Trigger；
- `"bypass"`：明确的单板运行旁路。它允许无 XS20 的 XS18 -> XS19
  物理回环，但不等同于同步完成。

成功返回 `0`。

#### `sync(epoch=1) -> int`

仅 `external` 模式的主卡可调用。该 API 在 XS20 上输出**一次** SYNC 脉冲并
携带 epoch，成功返回 `0`。从卡调用或 bypass 模式调用会抛出
`SynchronizationError`。它不是播放 Trigger：在已经完成该 epoch 后，随后
多次 Trigger 不需要再次调用它。

#### `emit_trigger() -> int`

在 XS18 输出一个 Trigger 脉冲，成功返回 `0`。它只发外部 Trigger，不直接
启动本机播放；通常在从板已 ARM 且 XS20 SYNC 完成后由主板调用。单板回环时
使用 `bypass`，把 XS18 与 XS19 物理短接后调用此 API。

#### `trigger() -> int` 与 `emit_trigger() -> int`

`trigger()` 是本机 UDP 软件 Trigger，直接作用于本机播放控制，不驱动 XS18。
`emit_trigger()` 是 XS18 物理 Trigger 输出，只有在电缆将其接至某个 XS19
输入时才会触发对应输入路径。外部 Trigger 测试不应把 `trigger()` 作为
`emit_trigger()` 的替代。

#### 外部 SYNC 从板示例

```python
from dr47 import Dr47Device

with Dr47Device(
    ip="169.254.32.1",
    udp_interface="enp225s0f1",
    udp_source_ip="169.254.250.11",
) as device:
    device.set_sync_role("slave")  # 验证已烧写 slave bitstream
    device.require_external_sync()
    # Upload a trigger-waiting waveform/sequence and configure CH1 first.
    device.arm(channel_mask=0x01)

    # An external source now provides one XS20 rising edge. After it is seen,
    # every XS19 rising edge triggers one execution of that sequence.
    caps = device.status().capabilities
    if not (caps.sync_seen and caps.sync_link_ready):
        raise RuntimeError("waiting for the physical XS20 SYNC pulse")
```

#### XS18 -> XS19 单板回环示例

```python
from dr47 import Dr47Device

with Dr47Device(
    ip="169.254.32.1",
    udp_interface="enp225s0f1",
    udp_source_ip="169.254.250.11",
) as device:
    device.set_sync_role("slave")  # 验证已烧写 slave bitstream
    device.bypass_sync()  # Explicit XS20 gate bypass.
    # Upload a trigger-waiting waveform/sequence and configure CH1 first.
    device.arm(channel_mask=0x01)
    device.emit_trigger()                  # XS18 -> physical cable -> XS19
    caps = device.status().capabilities
    print(caps.trigger_output_count, caps.trigger_accepted_count)
    device.abort_mute()
```

### 直接 RFCTRL2 方法

这些方法保留给网页后端、协议调试和需要自行管理 sequence 的程序。普通用户
优先使用上一节的高层方法。

| 方法 | 参数重点 | 返回值 |
| --- | --- | --- |
| `rfctrl2_hello(seq=None, wait_response=True)` | HELLO 探测 | 原始 RFRESP2 字典或发送字节数 |
| `rfctrl2_status(seq=None, wait_response=True, retries=None)` | STATUS 查询 | 原始 RFRESP2 字典或发送字节数 |
| `rfctrl2_rfdc_apply(per_channel_nco_hz, per_channel_nyquist_zone, per_channel_phase_deg, per_channel_output_current_ma, revision, channel_mask=0xFF, seq=None, wait_response=True, retries=None)` | 低层单位为 Hz、degree、mA | 解析后的 RFDC 回读字典 |
| `rfctrl2_rfdc_get_config(seq=None, ...)` | 读取 RFDC 配置 | RFDC 回读字典 |
| `rfctrl2_arm(run_id, channel_mask=0xFF, ...)` | 原始 ARM | RFRESP2 字典 |
| `rfctrl2_trigger(...)` | 原始本地 Trigger | RFRESP2 字典 |
| `rfctrl2_abort_mute(...)` | 原始停止/静音 | RFRESP2 字典 |
| `rfctrl2_sync_epoch(epoch, ...)` | 原始同步 epoch | RFRESP2 字典 |
| `rfctrl2_start_at(start_tick, ...)` | 指定 tick 启动 | RFRESP2 字典 |
| `rfctrl2_set_sync_role(role, mode=0, ...)` | role/mode 使用协议整数 | RFRESP2 字典 |
| `rfctrl2_emit_trigger(...)` | 原始 XS18 Trigger | RFRESP2 字典 |
| `rfctrl2_network_get(...)` | 读取网络身份 | 解析后的网络字典 |
| `rfctrl2_network_apply(revision, ip, mac, subnet_mask=..., gateway=..., port=..., ...)` | 暂存新网络身份 | 解析后的旧身份网络字典 |
| `rfctrl2_network_restart(...)` | 提交暂存网络身份 | 解析后的网络字典 |

`wait_response=False` 时通常返回发送的字节数，不会等待板卡确认。底层方法
的 NCO 参数是整数 Hz，与高层 `apply_rfdc_config(nco_ghz=...)` 不同。

## 5. 波形与序列工具

### 波形格式转换

#### `ezq_wave_to_interleaved_int16(wave, wave_format="packed_iq") -> np.ndarray`

统一转换为小端 IQ 交错 int16：`I0,Q0,I1,Q1,...`。

支持的 `wave_format`：

| 格式 | 输入 |
| --- | --- |
| `iq_matrix` | `(2,N)` 或 `(N,2)` 的 I/Q 矩阵 |
| `packed_iq` | 每个元素为 `Q << 16 \| I` 的 int32 |
| `interleaved_iq` | 已经是交错 int16 |
| `z` / `real` | 实数波形，自动补 Q=0 |

#### `ezq_wave_to_packed_int32(wave, wave_format="packed_iq") -> np.ndarray`

转换为 `Q << 16 | I` 的 int32 数组。

#### `waveform_bytes(wave) -> bytes`

把数组/列表转换为连续的小端 int16 字节串。

#### `waveform_length_bytes(samples) -> int`

按 32 字节 DAC beat 对齐后返回波形字节数。

### DDR 地址和数据包

| 函数 | 功能 | 返回值 |
| --- | --- | --- |
| `tiled_ddr_addr(channel, byte_offset, base_addr=0)` | tiled 布局的通道地址 | `int` |
| `tiled_channel_base_addr(channel, base_addr=0)` | tiled 通道起始地址 | `int` |
| `interleaved_ddr_addr(channel, byte_offset, base_addr=0)` | 交错布局的通道 lane 地址 | `int` |
| `interleaved_channel_lane_addr(channel, base_addr=0)` | 交错布局通道 lane 起始地址 | `int` |
| `pack_interleaved_512b_waveforms(channel_waves)` | 生成 512-bit 交错 DDR 镜像 | `(bytes, sample_count)` |
| `pack_udp_instruction_packet(commands)` | 生成 WAVEINS0 指令 UDP 包 | `bytes` |
| `iter_udp_waveform_packets(wave_bytes, ddr_addr, sample_count=None)` | 生成普通 DDR 写包迭代器 | iterator |
| `iter_tiled_udp_waveform_packets(wave_bytes, channel, base_addr=0, sample_count=None)` | 生成 tiled DDR 写包迭代器 | iterator |
| `iter_interleaved_udp_waveform_packets(channel_waves, base_addr=0)` | 生成交错 DDR 写包迭代器 | iterator |
| `iter_max_length_udp_batches(bytes_per_channel, base_addr=0, beats_per_datagram=4, **kwargs)` | 生成兼容的批量写包 | iterator |

### ez-Q 序列

#### `PulseWave(amplitude, duration)`

生成固定幅度脉冲。`duration` 单位为秒，当前内部采样率为 2 GS/s。

```python
pulse = PulseWave(amplitude=12000, duration=100e-9)
wave = pulse.generate()       # np.ndarray[int32]
```

#### `SequenceGenerator(channel_type, time_data, event_data, mark_data=None, period=0, repeat=0, delay=0, mark_delay=0, offset=0)`

生成 ez-Q 兼容波形和 4-word 控制序列。`channel_type` 可为 `XY`、`Z`、
`RI`、`RO`；当前硬件播放主要使用 XY/Z/RO 输出。

- `TriggerSeqGenerate()`：返回 `(wave_data, seq_data)`，适合一次/触发序列。
- `ContinueSeqGenerate()`：返回连续重复的 `(wave_data, seq_data)`。

`repeat` 必须为正数；`seq_data` 形状为 `(N, 4)`，dtype 为小端 `uint16`。

#### `TriggerSeqGenerate(*args, **kwargs)`

函数式封装：可以传入 `SequenceGenerator` 实例，也可以直接传构造参数。

```python
wave, sequence = TriggerSeqGenerate(
    "XY",
    time_data=[0.0],
    event_data=[PulseWave(10000, 40e-9)],
    period=1e-6,
    repeat=1,
)
```

#### `ezq_sequence_rows(sequence) -> np.ndarray`

把 flat 4-word 序列或 `(N,4)` 序列规范化为 `(N,4)` 小端 `uint16`。

#### `ezq_sequence_flags(sequence) -> dict[str, bool]`

返回 `has_trigger`、`has_loop_start`、`has_loop_end`、`has_delay`、
`has_stop` 等标记。

#### `sequence_to_play_commands(sequence, *, channel, wave_format="packed_iq", base_addr=0) -> (commands, metadata)`

把支持的 ez-Q 序列转换成当前 PL 的三类播放指令。返回指令列表和包含
`wait_for_trigger`、`loop`、`loop_count`、`rows` 的 metadata。嵌套循环、条件
跳转和当前 PL 不支持的控制字会抛出 `UnsupportedSequenceError`。

## 6. 传输接口

### `UdpTransport(ip, port=1234, timeout_s=5.0, udp_interface="", udp_source_ip="", socket_factory=None, sock=None)`

底层 UDP 传输对象。普通应用无需直接创建；网络发现 API 和 `Dr47Device` 会
自动使用它。

| 方法 | 功能 | 返回值 |
| --- | --- | --- |
| `address` | 目标 `(ip, port)` | tuple |
| `send(packet)` | 发送一个 UDP 数据包 | 发送字节数 |
| `request(packet, seq, opcode, retries=0, wait_response=True)` | 发送并按 sequence/opcode 等待回复 | RFRESP2 字典或字节数 |
| `receive_rfresp2(expected_seq=None, expected_opcode=None)` | 接收一条匹配回复 | dict |
| `receive_rfresp2_many(expected_seq=None, expected_opcode=None, timeout_s=1.0)` | 收集广播的多条回复 | `list[dict]` |
| `close()` | 关闭 socket | `None` |

`UDPTransport` 是 `UdpTransport` 的别名。

### `SimulatedDr47Device`

`SimulatedDr47Device(*args, device_uid="sim-xczu47dr", **kwargs)` 是内存中的
确定性模拟器，继承 `Dr47Device` 的高层 API，不创建真实 UDP socket，适合单元
测试和没有板卡时验证调用顺序。

```python
from dr47 import SimulatedDr47Device

sim = SimulatedDr47Device(device_uid="test-board")
sim.connect()
sim.apply_rfdc_config(nco_ghz={1: 1.0}, channel_mask=0x01)
sim.set_qc_on_off("xy", 1, "on")
sim.arm(channel_mask=0x01)
sim.trigger()
assert sim.status(refresh=False).capabilities.device_uid == "test-board"
sim.close()
```

模拟器会模拟 RFDC 配置、ARM、播放、同步和 Trigger 计数，但不能替代真实
板卡对 HMC7044、SYSREF、10G 链路、DDR 写入吞吐或物理 Trigger 线的验证。

## 7. 协议包和校验辅助函数

这些函数在 `dr47.protocol` 中导出，适合协议分析、抓包测试和自定义传输层。
普通发波程序不需要手工调用它们。

### RFCTRL2 打包函数

| 函数 | 功能 | 返回值 |
| --- | --- | --- |
| `pack_rfctrl2_packet(opcode, payload=b"", seq=1, flags=0)` | 生成通用 RFCTRL2 包 | `bytes` |
| `pack_rfctrl2_hello(seq=1)` | HELLO 请求 | `bytes` |
| `pack_rfctrl2_status(seq=1)` | STATUS 请求 | `bytes` |
| `pack_rfctrl2_arm(run_id, channel_mask=0xFF, seq=1)` | ARM 请求 | `bytes` |
| `pack_rfctrl2_trigger(seq=1)` | 本地 Trigger 请求 | `bytes` |
| `pack_rfctrl2_abort_mute(seq=1)` | 停止/静音请求 | `bytes` |
| `pack_rfctrl2_sync_epoch(epoch, seq=1)` | 同步 epoch 请求 | `bytes` |
| `pack_rfctrl2_start_at(start_tick, seq=1)` | 指定 tick 启动请求 | `bytes` |
| `pack_rfctrl2_set_sync_role(role, mode=0, seq=1)` | 设置同步角色/模式 | `bytes` |
| `pack_rfctrl2_emit_trigger(seq=1)` | XS18 Trigger 请求 | `bytes` |
| `pack_rfctrl2_rfdc_apply(...)` | 低层 RFDC 配置请求 | `bytes` |
| `pack_rfctrl2_rfdc_get_config(seq=1)` | RFDC 配置读取请求 | `bytes` |
| `pack_rfctrl2_network_apply(revision, ip, mac, subnet_mask=..., gateway=..., port=..., seq=1)` | 网络身份配置请求 | `bytes` |
| `pack_rfctrl2_network_get(seq=1)` | 网络身份读取请求 | `bytes` |
| `pack_rfctrl2_network_restart(seq=1)` | 提交网络身份并重启协议栈 | `bytes` |

`pack_rfctrl2_rfdc_apply()` 的 NCO 参数是整数 Hz；其余单位与对应的底层
RFCTRL2 字段一致。所有整数采用小端编码。

### RFRESP2 和 payload 解析函数

| 函数 | 功能 | 返回值 |
| --- | --- | --- |
| `parse_rfresp2_packet(packet, validate_version=True)` | 校验 RFRESP2 包头、版本、长度和 opcode | dict |
| `parse_rfctrl2_status_payload(response)` | 解析 STATUS payload | dict |
| `parse_rfctrl2_rfdc_config_response(response)` | 解析 RFDC 回读 payload | dict |
| `parse_rfctrl2_network_response(response)` | 解析网络身份 payload | dict |
| `normalize_rfdc_phase_mdeg(phase_deg)` | degree 转成毫度并归一到 `-180..180` | `int` |
| `validate_udp_bulk_beats(beats_per_datagram)` | 检查 UDP bulk beat 数 | `int` |
| `align_bytes_to_beat(n_bytes)` | 向 32 字节 beat 对齐 | `int` |
| `require_beat_aligned(value, name="value")` | 检查并返回已对齐值 | `int` |

解析函数遇到魔数、版本、长度或字段非法时抛出 `ProtocolError` 或
`ProtocolVersionError`。

## 8. 命令行 API

安装驱动后，入口命令为 `dr47-network`。

### `prepare-interface`

```bash
dr47-network prepare-interface \
  --interface enp225s0f0 \
  --source-ip 169.254.250.10/16
```

显式配置临时发现地址，需要管理员权限或相应 Linux capability。

### `discover`

```bash
dr47-network discover \
  --interface enp225s0f0 \
  --source-ip 169.254.250.10 \
  --json
```

只读广播发现。`--source-cidr`、`--broadcast-ip`、`--port`、`--timeout`、
`--rounds` 可覆盖默认值。

### `plan`

```bash
dr47-network plan \
  --interface enp225s0f0 \
  --source-ip 169.254.250.10 \
  --ip-pool 10.50.0.101-10.50.0.120
```

发现板卡并按 `device_uid` 排序预览 IP 映射；不会修改板卡。

### `provision`

```bash
dr47-network provision \
  --interface enp225s0f0 \
  --source-ip 169.254.250.10 \
  --device-uid 47d0xxxxxxxxxxxx \
  --ip 10.50.0.101 \
  --mac 02:50:00:00:00:01
```

重新发现目标 UID，显式执行配置、重启和新 IP 验证。

### `status` / `connect`

```bash
dr47-network status \
  --interface enp225s0f0 \
  --ip 10.50.0.101 \
  --json
```

当前两个命令都会连接并读取一次状态；`connect` 名称用于脚本语义兼容。

## 9. 完整从头到尾示例

下面示例假设：

- 交换机是二层交换机，主机和板卡在同一 VLAN；
- 主机 10G 网卡名为 `enp225s0f0`；
- 两块板卡烧写完成后都使用 DNA 派生的 `169.254.x.y/16` 地址；
- 正式控制网段为 `10.50.0.0/24`；
- 主卡 XS20 接从卡 XS20，主卡 XS18 接从卡 XS19；
- 两块板卡已接入同一个 250 MHz 参考时钟，并由各自 HMC7044/RFDC 完成时钟初始化。

```python
#!/usr/bin/env python3
"""交换机后双板卡：发现、配置、连接、同步、发波和外部 Trigger。"""

from dataclasses import replace

import numpy as np

from dr47 import (
    Dr47Device,
    discover_boards,
    prepare_interface,
    provision_board,
)


INTERFACE = "enp225s0f0"
DISCOVERY_SOURCE_IP = "169.254.250.10"
DISCOVERY_SOURCE_CIDR = "169.254.250.10/16"


def main() -> None:
    # 1. 给主机 10G 网卡配置临时发现地址。
    #    这一步会修改操作系统网络，需要 CAP_NET_ADMIN/root。
    prepare_interface(INTERFACE, DISCOVERY_SOURCE_CIDR)

    # 2. 广播 NETWORK_GET，收集交换机后所有板卡。
    #    该函数只读，不会修改板卡网络配置。
    discovered = discover_boards(
        interface=INTERFACE,
        source_ip=DISCOVERY_SOURCE_IP,
        source_cidr=DISCOVERY_SOURCE_CIDR,
        rounds=3,
    )
    for board in discovered:
        print(board.device_uid, board.current_ip, board.current_mac, board.build_profile)

    # 3. 必须由用户/实验配置明确决定哪个 UID 是主卡、哪个 UID 是从卡。
    #    不要根据交换机端口或发现列表顺序猜测角色。
    master_uid = "请替换为主卡的 device_uid"
    slave_uid = "请替换为从卡的 device_uid"
    master_record = next(b for b in discovered if b.device_uid == master_uid)
    slave_record = next(b for b in discovered if b.device_uid == slave_uid)

    # 4. 给两块板卡分配不同的正式 IP/MAC。
    #    provision_board 内部执行 NETWORK_APPLY -> NETWORK_RESTART -> 新 IP 回读。
    master_net = provision_board(
        master_record,
        ip="10.50.0.101",
        mac="02:50:00:00:00:01",
        known_boards=discovered,
    )
    slave_net = provision_board(
        slave_record,
        ip="10.50.0.102",
        mac="02:50:00:00:00:02",
        known_boards=discovered,
    )
    print("master network verified:", master_net.as_dict())
    print("slave network verified:", slave_net.as_dict())

    # 5. 给主机 10G 网卡增加正式控制网段地址。
    #    板卡已经切换到 10.50.0.x；后续单播控制使用同一网段源地址。
    prepare_interface(INTERFACE, "10.50.0.10/24")

    # 6. 使用正式 IP 建立普通单板驱动对象。
    master = Dr47Device(
        ip=master_net.ip,
        port=master_net.port,
        udp_interface=INTERFACE,
        udp_source_ip="10.50.0.10",
        batch_mode=True,
    )
    slave = Dr47Device(
        ip=slave_net.ip,
        port=slave_net.port,
        udp_interface=INTERFACE,
        udp_source_ip="10.50.0.10",
        batch_mode=True,
    )

    try:
        # 7. HELLO + STATUS，确认两块板卡确实是预期身份并且 RFCTRL2 在线。
        master.connect()
        slave.connect()
        assert master.capabilities.device_uid == master_uid
        assert slave.capabilities.device_uid == slave_uid

        # 8. 配置同步角色和正式外部模式。
        #    bypass 只用于单板本地运行，跨板联调必须使用 external。
        master.set_sync_mode("external")
        slave.set_sync_mode("external")
        master.set_sync_role("master")
        slave.set_sync_role("slave")

        # 9. 为两块板卡配置相同的 DAC NCO 和相位。
        #    高层单位是 GHz/degree/mA；batch_mode=True 时最后统一 commit。
        rfdc = {
            "nco_ghz": {1: 1.0},
            "nyquist_zone": {1: 1},
            "phase_deg": {1: 0.0},
            "output_current_ma": {1: 20.0},
            "channel_mask": 0x01,
        }
        master.apply_rfdc_config(**rfdc, revision=1)
        slave.apply_rfdc_config(**rfdc, revision=1)
        master.commit()
        slave.commit()

        # 10. 准备一个很短的 DC-IQ 波形。
        #    DC 复基带 + 1 GHz NCO = 1 GHz 模拟输出；I/Q 交错为 I0,Q0,I1,Q1...
        samples = 1024
        iq = np.zeros((2, samples), dtype=np.int16)
        iq[0, :] = 12000

        # 11. 上传相同波形，打开 CH1，但此处不自动本地触发。
        master.upload_waveforms(
            {1: iq},
            wave_formats={1: "iq_matrix"},
            auto_start=False,
            packet_pause_s=1e-5,
            packet_burst=8,
        )
        slave.upload_waveforms(
            {1: iq},
            wave_formats={1: "iq_matrix"},
            auto_start=False,
            packet_pause_s=1e-5,
            packet_burst=8,
        )
        master.set_qc_on_off("xy", 1, "on")
        slave.set_qc_on_off("xy", 1, "on")

        # 12. 主卡发出一次外部 SYNC epoch。
        #     这要求 XS20 物理线和参考时钟已经正确连接。
        master.sync(epoch=1)

        # 13. 两块板卡都 ARM，进入等待 Trigger 状态。
        master.arm(channel_mask=0x01, run_id=1001)
        slave.arm(channel_mask=0x01, run_id=1001)

        # 14. 主卡在 XS18 输出 Trigger，经物理线到从卡 XS19。
        #     这不是 master.trigger()；master.trigger() 只启动主卡本地播放。
        master.emit_trigger()

        # 15. 读取状态，确认两块板卡均已进入播放或至少接受 Trigger。
        master_status = master.status()
        slave_status = slave.status()
        print("master:", master_status.state, master_status.capabilities.trigger_output_count)
        print("slave:", slave_status.state, slave_status.capabilities.trigger_accepted_count)
    finally:
        # 16. 无论中途哪一步失败，都关闭 socket；停止播放可按实验需要显式调用。
        master.close()
        slave.close()


if __name__ == "__main__":
    main()
```

这个示例中的两个 UID、参考时钟和 XS20/XS18/XS19 连接必须按实际设备替换和
确认。`provision_board()` 成功只说明网络身份已经切换并验证，不代表 RFDC、
HMC7044、SYSREF 或外部同步链路已经就绪；这些状态应通过 `status()` 中的
`DeviceCapabilities` 检查。

## 10. 异常与故障处理

所有异常都继承自 `DriverError`：

| 异常 | 典型原因 |
| --- | --- |
| `ConnectionError` | 网卡、路由、权限或板卡不可达 |
| `ConnectionStateError` | 未 `connect()` 就调用需要连接的方法，或对象已关闭 |
| `TransportError` | socket 发送/接收失败 |
| `TransportTimeout` | 在超时时间内没有收到回复 |
| `ProtocolError` | RFCTRL2/RFRESP2 包损坏或长度错误 |
| `ProtocolVersionError` | 驱动与 bitstream 协议版本不一致 |
| `DeviceStatusError` | 板卡返回非 OK 状态 |
| `DeviceBusyError` | 板卡正在执行不能打断的操作 |
| `DeviceNotReadyError` | RFDC/MTS/播放前置条件未满足 |
| `ParameterRangeError` | IP、MAC、频率、通道、掩码等参数非法 |
| `UnsupportedCapabilityError` | 当前 bitstream 没有对应能力，如 DAQ/PUMP |
| `UnsupportedSequenceError` | ez-Q 序列包含当前 PL 不支持的指令 |
| `WaveformFormatError` | 波形维度、dtype 或格式不正确 |
| `SynchronizationError` | 角色/模式不允许执行同步操作 |
| `SyncRequiredError` | 尚未完成外部同步就执行依赖同步的操作 |
| `DiscoveryError` | 广播发现没有有效板卡回复 |
| `ProvisionError` | 网络配置、重启或新 IP 验证失败 |

推荐捕获方式：

```python
from dr47 import DriverError, ProvisionError, TransportTimeout

try:
    device.connect()
except TransportTimeout:
    print("板卡没有在超时时间内回复")
except DriverError as exc:
    print(f"驱动操作失败: {exc}")
```

## 11. 当前能力边界

- 当前驱动主要控制 DAC/RFDC 播放；DAQ、ADC 输入、demod 和 pump 接口会明确
  抛出 `UnsupportedCapabilityError`，不会伪造成功。
- `trigger()` 是本机软件 Trigger；`emit_trigger()` 是 XS18 外部 Trigger 输出。
- `bypass_sync()` 只用于明确的本地运行旁路，不等同于跨板同步。
- 多块板卡共用一条主机 10G 上联时，控制包和同步包正常，但同时上传大波形
  会竞争该 10G 链路；应降低并发或增加上联带宽。
- 交换机必须允许同一 VLAN 内的广播才能完成首次自动发现；正式 IP 配置后，
  日常控制使用单播，不依赖广播。
