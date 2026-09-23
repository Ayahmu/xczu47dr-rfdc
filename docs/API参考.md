# 47DR Python API 参考

本文面向使用 `47dr-driver` 编写控制程序的开发者。示例使用 Python 3.10 以上版本，
频率单位为 GHz，时间单位为 ns（波形生成函数中以 `_s` 结尾的参数使用秒），网络
和 RFDC 操作均通过 UDP 端口 1234 完成。

## 安装与导入

```bash
python -m pip install 47dr_driver-0.1.0-py3-none-any.whl
```

```python
from dr47 import Dr47Device
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
    batch_mode=False, transport=None,
    expected_build_profile_id=1,
    expected_trigger_path_version=3,
    expected_source_commit_id=None,
)
```

| 参数 | 说明 |
| --- | --- |
| `ip`, `port` | 板卡地址和 UDP 端口。 |
| `timeout_s`, `retries` | 请求超时和重试次数。 |
| `udp_interface`, `udp_source_ip` | 多网卡主机上指定发送网卡和源地址。 |
| `batch_mode` | 为 `True` 时，RFDC 设置暂存到 `commit()`。 |
| `expected_*` | 身份保护条件；设为 `None` 可关闭对应检查。 |

构造对象不会访问网络。常用生命周期方法如下：

```python
device.connect()                 # 返回板端协议版本
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
每通道 `RfdcChannelReadback`。播放状态为 `idle`、`upload`、`ready`、`prefetch`、`wait_trigger`、`playing`、
`draining`、`done`、`error` 或 `fault`。

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

### 底层协议方法

需要精确控制协议时可使用 `rfctrl2_hello()`、`rfctrl2_status()`、
`rfctrl2_rfdc_apply(...)` 和 `rfctrl2_rfdc_get_config()`。这些方法只覆盖身份、状态、
RFDC 配置和诊断；波形播放必须使用下面的 WAVECTR0 方法，不再提供旧 ARM、TRIGGER、
ABORT_MUTE 或 instruction-stream 入口。

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
- `make_burst_record(active_wave, *, first_delay_ns, interval_ns, sample_rate_hz=400e6)`：生成带零填充间隔的波形记录和描述字典；它不创建板端播放指令。
- `ezq_wave_to_interleaved_int16(wave, wave_format="packed_iq")`：完成输入格式转换。

### 上传和播放配置

波形协议为单板专用的 `WAVECTR0`，不再提供旧 ARM、PREPARE、RFCTRL2 TRIGGER 或
ABORT_MUTE 播放命令。8 个通道使用统一的交织 512-bit DDR 图像：每个 DDR beat 为 64 bytes，每个通道占 8 bytes；四个 DDR beat 组成每通道一个 32-byte DAC beat。
`total_beats` 表示每通道 DAC beat 数，`total_bytes = total_beats * 256`，不因 mask 缩短。所有地址和长度均以 bytes 或 beats 明确表达。

低层接口如下：

```python
board.begin_waveform(
    session=1, total_bytes=len(image), channel_mask=0x03,
    total_beats=len(image) // 256, loop_count=1,
)
for packet_seq, offset in enumerate(range(0, len(image), 1024)):
    board.data_waveform(
        session=1, packet_seq=packet_seq, byte_offset=offset,
        payload=image[offset:offset + 1024],
    )
board.commit_waveform(session=1)
board.play(session=1)
board.pause(session=1)
board.stop(session=1)
board.abort(session=1)
print(board.waveform_status(session=1))
```

`DATA` 由设备按期望 sequence 接收；缺包、乱序、越界和 CRC 错误不会改变累计确认。
重复包只返回当前 `next_expected_sequence` 和 `received_bytes`。`COMMIT` 只有在全部
bytes 连续接收后成功，并自动进入 `PREFETCH`。启动水位达到后进入 `WAIT_TRIGGER`；
`PLAY` 或合法外部 Trigger 的第一个事件进入 `PLAYING`。`PAUSE`/`STOP` 清空 FIFO 并
保留 descriptor，下一次 `PLAY` 从波形起点重新预取；`ABORT` 清除 descriptor 和错误。

`upload_waveforms()` 是上述流程的便捷封装，会把输入通道补零并打包为统一 interleaved
图像，然后执行 BEGIN、DATA 和 COMMIT。`loop_count` 表示包含首轮在内的总播放次数；
它不接受 instruction sequence 或播放延迟参数。

## 外部 Trigger

外部窄脉冲由板端异步置位 latch 捕获，再经过约束的同步路径进入 DAC 域。Trigger
只在 `WAIT_TRIGGER` 状态被消费；在 `IDLE`、`UPLOAD`、`PREFETCH`、`READY`、`PLAYING`
或 `ERROR` 中到达的事件都会丢弃，不会形成待启动请求。状态查询中的计数区分
`trigger_seen_count`、`trigger_dropped_count` 和实际启动计数。

单板播放不依赖 HMC 多板同步、软件回包或旧 GPIO 门控路径。

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
