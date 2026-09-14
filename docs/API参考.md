# 47DR Python API 参考

本文面向使用 `47dr-driver` 编写控制程序的开发者。示例使用 Python 3.10 以上版本，
频率单位为 GHz，时间单位为 ns（波形生成函数中以 `_s` 结尾的参数使用秒），网络
和 RFDC 操作均通过 UDP 端口 1234 完成。

## 安装与导入

```bash
python -m pip install 47dr_driver-0.1.0-py3-none-any.whl
```

```python
from dr47 import Dr47Device, BurstSchedule
```

SDK ZIP 中的 `examples/` 目录包含模拟器、网络发现、软件 Trigger 和外部 Trigger
示例。先运行模拟器示例可以在没有板卡时检查安装：

```bash
python -m dr47.examples.simulator_quickstart
```

## 连接与身份校验

### `Dr47Device`

```python
Dr47Device(
    ip="192.168.1.128", port=1234, timeout_s=5.0,
    udp_interface="", udp_source_ip="", retries=2,
    batch_mode=False, sync_role="slave", transport=None,
    expected_build_profile_id=1,
    expected_trigger_path_version=3,
    expected_source_commit_id=None,
)
```

| 参数 | 说明 |
| --- | --- |
| `ip`, `port` | 板卡地址和 RFCTRL2 UDP 端口。 |
| `timeout_s`, `retries` | 请求超时和重试次数。 |
| `udp_interface`, `udp_source_ip` | 多网卡主机上指定发送网卡和源地址。 |
| `batch_mode` | 为 `True` 时，RFDC 设置暂存到 `commit()`。 |
| `sync_role` | 软件期望的角色；只能配置为 `master` 或 `slave`，不能改变 bitstream 固化的角色。 |
| `expected_*` | 身份保护条件；设为 `None` 可关闭对应检查。 |

构造对象不会访问网络。常用生命周期方法如下：

```python
device.connect()                 # 返回 RFCTRL2 协议版本
status = device.status()         # 返回 DeviceStatus
status_cached = device.status(refresh=False)
caps = device.capabilities       # DeviceCapabilities
print(caps.device_uid, caps.build_profile, caps.trigger_path_version)
device.close()
```

也可以使用工厂函数 `connect(**same_arguments) -> Dr47Device`，或用上下文管理器自动
关闭连接。`connect()` 会读取 HELLO/STATUS；协议、build profile 或 Trigger 路径版本
不匹配时抛出 `ProtocolVersionError`。

`DeviceStatus` 包含 `connected`、`ip`、`port`、`state`、`capabilities` 和 `message`。
`DeviceCapabilities` 还提供 RFDC/MTS/NCO 状态、同步状态、Trigger 计数、播放状态和
每通道 `RfdcChannelReadback`。播放状态为 `idle`、`armed`、`prepared`、`running` 或
`fault`。

## 网络发现与配置

```python
from dr47 import (
    discover_boards, connect_discovered, provision_board,
    prepare_interface, parse_ip_pool,
)

prepare_interface("enp1s0f0", "169.254.250.11/16")
boards = discover_boards(
    interface="enp1s0f0", source_ip="169.254.250.11",
    source_cidr="169.254.250.11/16",
)
board = boards[0]
device = connect_discovered(board)
```

| 函数 | 参数和返回值 |
| --- | --- |
| `prepare_interface(interface, source_cidr)` | 配置主机网卡地址；需要相应 Linux 网络权限；返回 `None`。 |
| `discover_boards(interface, source_ip, source_cidr, broadcast_ip, port, timeout_s, rounds)` | 广播发现板卡，返回 `list[DiscoveredBoard]`。身份应使用 `device_uid + current_mac`。 |
| `connect_discovered(board, timeout_s=5, retries=2)` | 根据发现结果创建并连接 `Dr47Device`。 |
| `provision_board(board, ip, mac=None, subnet_mask=..., gateway=..., port=..., revision=None, known_boards=(), reject_unverified_conflict=False, verification_source_ip=None)` | 写入固定网络配置并验证，返回 `ProvisionedBoard`。 |
| `parse_ip_pool(value)` | 将 `10.50.0.101-10.50.0.120` 或逗号分隔地址解析为地址列表。 |

`DiscoveredBoard.as_dict()` 和 `ProvisionedBoard.as_dict()` 可直接用于 JSON。配置新
地址前必须确认 UID、MAC 和目标地址不会与其他板卡冲突；板卡处于播放状态时网络配置
可能返回状态码 `0x0006`。

## RFDC 配置

### 高层接口

```python
device.set_xy_target_frequency(channel=1, target_rf_ghz=4.0, dac_fs_ghz=6.4)
device.set_gain("xy", 1, gain=0.7, gain_type="norm")
device.set_qc_on_off("xy", 1, "on")
device.commit()
```

| 方法 | 参数 | 返回值和行为 |
| --- | --- | --- |
| `set_xy_target_frequency(channel, target_rf_ghz, dac_fs_ghz=6.4)` | 通道 1-8、目标模拟频率和 DAC 采样率。 | 返回 NCO/Nyquist 规划字典；目标频率必须在 `[0, dac_fs_ghz]`。 |
| `set_xy_nco_frequency(channel, frequency_ghz)` | 通道 1-8，RFDC NCO，范围约 `-3.2..3.2 GHz`。 | 返回状态码。 |
| `set_gain(channel_type, channel, gain=1.0, gain_type="norm")` | `channel_type` 为 `xy` 或 `z`；`gain_type` 为 `norm`、`dbm`、`code` 或 `volt`。 | 返回状态码；`norm` 取值 `0..1`。 |
| `set_qc_on_off(channel_type, channel, on_off="on")` | 输出类型、通道和 `on`/`off`。 | 返回状态码。 |
| `set_qr_on_off(gen_type, channel, on_off="on")` | 读取/DAQ 路径控制；当前硬件不支持 ADC 输入。 | 返回状态码或抛出 `UnsupportedParameterError`。 |
| `apply_rfdc_config(nco_ghz=None, nyquist_zone=None, phase_deg=None, output_current_ma=None, revision=None, channel_mask=0xff)` | Mapping（键为通道号）或 8 项 Sequence；可一次提交多通道。 | 返回状态码。 |
| `commit()` | 无参数。批量提交暂存的 RFDC 配置。 | 返回状态码。播放器必须处于 `idle`；忙时会抛出/处理 `DeviceBusyError`。 |

`set_xy_target_frequency(1, 4.0)` 会返回类似 `{"nco_ghz": -2.4,
"nyquist_zone": 2}` 的结果。4 GHz 的低频 IQ 包络不需要在主机端预先搬移到 RF
载波。

### 底层 RFCTRL2 方法

需要精确控制协议时可使用 `rfctrl2_hello()`、`rfctrl2_status()`、
`rfctrl2_rfdc_apply(...)`、`rfctrl2_rfdc_get_config()`、`rfctrl2_arm(...)`、
`rfctrl2_trigger()`、`rfctrl2_abort_mute()`。这些方法直接使用协议字段，返回解析后
字典或状态码；一般应用应优先使用上面的高层方法。

## 波形生成与上传

### 波形格式

驱动接受以下格式并统一转换为小端有符号 `int16` 的 `I0,Q0,I1,Q1,...`：

| `wave_format` | 输入形状 |
| --- | --- |
| `interleaved_iq` | 一维 `[I0,Q0,I1,Q1,...]`。 |
| `iq_matrix` | 二维 `N x 2`，列为 I、Q。 |
| `packed_iq` | 已打包的 IQ 样本。 |
| `z`、`real` | 一维实数/包络，按驱动规则转换。 |

```python
from dr47 import (
    make_iq_sine_interleaved, make_iq_gaussian_sine_interleaved,
    place_interleaved_iq_in_record, make_burst_record,
    ezq_wave_to_interleaved_int16,
)

wave = make_iq_gaussian_sine_interleaved(
    frequency_hz=50e6, phase_rad=0.0, amplitude=12000,
    sample_rate_hz=400e6, duration_s=2e-6, fwhm_s=0.6e-6,
)
record, info = make_burst_record(
    wave, first_delay_ns=0, interval_ns=1000, sample_rate_hz=400e6,
)
```

主要函数参数：

- `make_iq_sine_interleaved(frequency_hz, phase_rad, amplitude, sample_rate_hz, *, sample_count, q_sign=-1)`：生成固定样本数的正弦 IQ。
- `make_iq_gaussian_sine_interleaved(..., duration_s, *, sample_count=None, fwhm_s=None, q_sign=-1, hls_xy_drag=False, drag_alpha=0.5, drag_delta_hz=-200e6)`：生成高斯包络 IQ，可选 DRAG 修正。
- `place_interleaved_iq_in_record(active_wave, *, delay_s, record_duration_s, sample_rate_hz)`：将有效波形放入带前置零和尾部零的记录。
- `make_burst_record(active_wave, *, first_delay_ns, interval_ns, sample_rate_hz=400e6)`：生成一份有限 burst 记录和描述字典。
- `ezq_wave_to_interleaved_int16(wave, wave_format="packed_iq")`：完成输入格式转换。

### 上传和播放配置

```python
cfg = device.configure_playback(
    {1: wave, 2: wave},
    BurstSchedule(first_delay_ns=0, interval_ns=1000, repetitions=3),
    wave_formats={1: "interleaved_iq", 2: "interleaved_iq"},
    bulk_upload=True,
)
device.arm_playback(cfg.channel_mask)
device.trigger_playback()
device.abort_playback()
```

`configure_playback(channel_waves, schedule, *, wave_formats=None, channel_mask=None,
bulk_upload=False, **kwargs)` 会上传记录并返回 `PlaybackConfig`，其字段为
`schedule`、`channel_mask`、`record_duration_ns` 和 `record_bytes_per_channel`。
`channel_waves` 是 `{physical_channel: numpy_array_or_list}`，通道范围为 1-8。

需要更细控制时使用：

```python
device.upload_waveforms(
    {1: wave}, channel_sequences=None,
    wave_formats={1: "interleaved_iq"}, layout="interleaved_512b",
    base_addr=0, auto_start=True, loop=False,
    packet_pause_s=1e-5, packet_burst=8,
    channel_delays=None, instruction_repeats=1,
    bulk_upload=False, progress_callback=None, schedule=None,
)
```

`progress_callback(sent_packets, total_packets)` 在开始上传和每个数据包完成后调用。
`arm_playback(channel_mask=None, run_id=None)` 进入等待 Trigger 状态；
`trigger_playback()` 发送软件 Trigger；`abort_playback()` 停止播放并静音。旧名称
`arm()`、`trigger()`、`abort_mute()` 等价但仅用于兼容旧程序。

`BurstSchedule(first_delay_ns, interval_ns, repetitions, debug_alternate=False)` 的
时间在 FPGA 端按 20 ns 向上量化。`first_delay_ns=0` 表示不增加可编程等待；异步
外部输入仍会有一个 DAC 时钟边界量化。

## 同步与外部 Trigger

```python
device.set_sync_mode("bypass")       # 单板、没有 XS20 时
device.bypass_sync()
device.arm_playback(channel_mask=0x03)
# 此后等待 XS19 外部 Trigger
```

| 方法 | 说明 |
| --- | --- |
| `set_sync_role("master" / "slave")` | 设置协议请求的角色；不能覆盖 bitstream 固化角色。 |
| `set_sync_mode("external" / "bypass")` | 选择同步门控。单板外部 Trigger 通常使用 `bypass`。 |
| `bypass_sync()` / `require_external_sync()` | 快捷设置同步模式。 |
| `sync(epoch=1)` | 主卡发起同步 epoch；slave 调用会失败。 |
| `emit_trigger()` | 从 XS18 输出一个 Trigger，不会自动启动本地播放。 |
| `SyncGroup(master, slave, timeout_s=5).sync(epoch=1)` | 执行双板同步并返回 `SyncAlignmentResult`。 |

未准备好的外部 Trigger 不会排队，板卡会立即记录为 skipped/rejected；应用应通过
`status()` 或诊断快照检查接受计数。

## 诊断与错误处理

```python
snapshot = device.read_diagnostics()
print(snapshot.trigger_to_launch_last, snapshot.launch_to_first_valid_last)
device.clear_diagnostics(events=0xffffffff, counters=True)
```

`DiagnosticsSnapshot` 包含触发输入/接受/拒绝计数、capture/launch/playback 时间戳、
replay 状态、每通道 FIFO 水位、underflow/mute/abort、RFDC 状态和失败阶段、DMA
chunk/outstanding beat 以及 refill 起止时间。诊断寄存器在硬件侧先锁存，再通过快照
代次读取，适合定位延迟和状态竞态。

常见异常：`ConnectionError`（网络不可达）、`TransportTimeout`（响应超时）、
`ProtocolVersionError`（协议/身份不匹配）、`DeviceBusyError`（硬件忙）、
`DeviceNotReadyError`（未准备）、`ParameterRangeError`（参数越界）、
`UnsupportedCapabilityError`/`UnsupportedParameterError`（当前板卡不支持）和
`DeviceStatusError`（板端返回非零状态）。异常对象带有操作名和板端状态码。

## 版本与兼容性

当前公开包不包含 TDC 校准、补偿或 TDC 公共 API。驱动、XSA 和 ELF 应来自同一发布
版本；`software/load_and_verify.sh` 会从 XSA 提取内嵌 bitstream 与 `psu_init.tcl`，
不需要额外的 `.bit` 或 `_psu_init.tcl` 文件。
