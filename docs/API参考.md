# 47DR Python API 参考

本文面向使用 `47dr-driver` 编写控制程序的开发者。示例使用 Python 3.10 以上版本，
频率单位为 GHz，时间单位为 ns（波形生成函数中以 `_s` 结尾的参数使用秒），网络
和 RFDC 操作均通过 UDP 端口 1234 完成。

## 安装与导入

```bash
python -m pip install 47dr_driver-<版本>-py3-none-any.whl
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
device.set_qc_on_off("xy", 1, "on")
device.commit()
```

| 方法 | 参数 | 返回值和行为 |
| --- | --- | --- |
| `set_xy_target_frequency(channel, target_rf_ghz, dac_fs_ghz=6.4)` | 通道 1-8、目标模拟频率和 DAC 采样率。 | 返回 NCO/Nyquist 规划字典；目标频率必须在 `[0, dac_fs_ghz]`。 |
| `set_xy_nco_frequency(channel, frequency_ghz)` | 通道 1-8，RFDC NCO，范围约 `-3.2..3.2 GHz`。 | 返回状态码。 |
| `set_qc_on_off(channel_type, channel, on_off="on")` | 输出类型、通道和 `on`/`off`。 | 返回状态码。 |
| `set_qr_on_off(gen_type, channel, on_off="on")` | 读取/DAQ 路径控制；当前硬件不支持 ADC 输入。 | 返回状态码或抛出 `UnsupportedParameterError`。 |
| `apply_rfdc_config(nco_ghz=None, nyquist_zone=None, phase_deg=None, revision=None, channel_mask=0xff)` | Mapping（键为通道号）或 8 项 Sequence；可一次提交多通道。 | 返回状态码。 |
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
    frequency_hz=50e6, phase_rad=0.0, amplitude=0.4,
    sample_rate_hz=400e6, duration_s=2e-6, fwhm_s=0.6e-6,
)
record, info = make_burst_record(
    wave, first_delay_ns=0, interval_ns=1000, sample_rate_hz=400e6,
)
```

输出强度只由波形样点幅度决定。`amplitude` 归一化到 `[-1, 1]`，`1` 是满幅（int16 的
32767，也是默认的最大输出）；负值表示反相。超出 `[-1, 1]` 或非有限值会抛出
`ParameterRangeError`，不会静默截断，所以旧代码里传入的整型 DAC 码会立即报错。

主要函数参数：

- `make_iq_sine_interleaved(frequency_hz, phase_rad, amplitude, sample_rate_hz, *, sample_count, q_sign=-1)`：生成固定样本数的正弦 IQ。
- `make_iq_gaussian_sine_interleaved(..., duration_s, *, sample_count=None, fwhm_s=None, q_sign=-1, hls_xy_drag=False, drag_alpha=0.5, drag_delta_hz=-200e6)`：生成高斯包络 IQ，可选 DRAG 修正。
- `place_interleaved_iq_in_record(active_wave, *, delay_s, record_duration_s, sample_rate_hz)`：将有效波形放入带前置零和尾部零的记录。
- `make_burst_record(active_wave, *, first_delay_ns, interval_ns, sample_rate_hz=400e6)`：生成带零填充间隔的波形记录和描述字典；它不创建板端播放指令。
- `ezq_wave_to_interleaved_int16(wave, wave_format="packed_iq", *, copy=True)`：完成输入格式转换；`copy=False` 时已是线上顺序的数据直接返回视图。

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
`PLAY` 或合法外部 Trigger 的第一个事件进入 `PLAYING`。`PAUSE`/`STOP` 回到 `READY`、
清空 FIFO 并保留 descriptor，下一次 `PLAY` 从波形起点重新预取；`ABORT` 清除
descriptor 和错误。`play()`、`pause()`、`stop()`、`abort()` 被板端拒绝时抛出
`DeviceStatusError`（例如在 `ERROR` 状态下 `PLAY`），不会静默返回。

`upload_waveforms()` 是上述流程的便捷封装，会把输入通道补零并打包为统一 interleaved
图像，然后执行 BEGIN、DATA 和 COMMIT（大图像自动改走下文的批量通路）。`loop_count` 表示包含首轮在内的总播放次数；
它不接受 instruction sequence 或播放延迟参数。各轮之间无缝衔接：DDR 读取器把所有轮次
连续送入 FIFO，DAC 输出在轮次边界不插入空闲拍；TRIG_1 在每一轮的第一拍各输出一次。
单轮过短时读取器的 DDR 往返延迟无法被流水掩盖，播放会以 underflow 进入 `ERROR`。
板上实测：单轮 2 拍（40 ns）在约 5000 轮后 underflow，3 拍（60 ns）及以上 2 秒连续循环
无 underflow。整条流（单轮拍数 × `loop_count`）不超过 1024 拍时会在开始前整体预取，
不受此限制。驱动在 BEGIN 前拒绝单轮少于 3 拍且整条流超过 1024 拍的组合
（`ParameterRangeError`）；需要更短的周期时，把记录重复到至少 3 拍再循环。

### 批量上传（100G 满速）

`DATA` 方式每包 1024 bytes、发一包等一包应答，实测只有约 12.9 MB/s。大波形走批量通路：
图像以不带逐包应答的 UDP 数据报发往“控制端口 + 1”，板卡在 100G MAC 之后直接以
512-bit 位宽写入 DDR4。

```python
result = board.upload_waveforms(channel_waves, wave_formats=formats)   # transport="auto"
print(result["transport"], result["resent_chunks"])
```

- `upload_waveforms(..., transport="auto" | "bulk" | "packet", bulk_threshold_bytes=1 << 20)`：
  `"auto"` 在图像不小于 1 MiB 且 bitstream 带批量通路时走批量通路，否则走 `DATA`；旧
  bitstream 会拒绝批量 `BEGIN`，驱动自动退回 `DATA`。返回值的 `transport` 说明实际走了哪条。
- `upload_image_bulk(image, *, session, channel_mask, total_beats, loop_count=1, payload_bytes=None, max_resends_per_chunk=8, progress_callback=None)`：
  上传一份已经打包好的图像（任意 bytes-like 对象）或一个 `LaneImage`，完成后 `COMMIT`。
- `dr47.waveforms.LaneImage(channel_waves, *, samples=0)`：描述“8 个通道数组打包后的图像”
  而不真的生成它；`len()` 是图像字节数，`pack(start, end)` 生成任意一段。批量通路直接从
  各通道数组边取数边发送，多 GB 的波形不需要第二份内存拷贝。
- `bulk_status(session=...)`、`bulk_chunk_reset(session=..., chunk=..., epoch=...)`：
  低层查询与补发控制，一般不需要直接调用。

可靠性：批量数据报没有逐包校验和应答，完整性依靠以太网 FCS 和 RS-FEC（坏帧整帧丢弃）。
板卡按 1 MiB 分块统计收到的字数；发送结束后驱动查询第一个不完整的分块，给它换一个新的
epoch 并只重发这一块，直到全部完整才 `COMMIT`。仍在路上的旧 epoch 数据报不会被计数，
因此重发不会把分块误判为完整。同一分块重发 `max_resends_per_chunk` 次仍不完整时抛出
`DeviceStatusError`，错误信息带链路收包数和丢包数。

板上实测（MTU 1500，每个数据报 1024 bytes 有效载荷，主机 4 个发送线程）：

| 项目 | 结果 |
|---|---|
| `upload_waveforms()`，8 通道 `int16` 数据，整片 DDR4（8191 MiB） | 0.75 s，91.6 Gb/s（约 11.5 GB/s），无丢包、无补发 |
| 线路占用 | 100 Gb/s（有效载荷占每帧 1112 bytes 线路开销中的 1024 bytes） |
| 发送线程数（8 通道数组边取数边发） | 1 线程约 35 Gb/s，2 线程约 67 Gb/s，3 线程 78–88 Gb/s，4 线程及以上跑满（驱动默认 4 线程） |
| 发送线程数（已打包好的图像） | 1 线程约 47 Gb/s，2 线程及以上跑满 |
| 数据正确性 | 64 MiB 全量、8 GiB 抽样 3398 处经 JTAG 从 DDR4 读回逐字节一致；人为丢包后补发的图像同样一致 |
| 播放 | 8191 MiB 上传后完整播放 33 550 336 拍，无 underflow；示波器上与 `DATA` 方式上传的同一记录输出一致 |

使用条件和限制：

- 主机为 Linux，网卡支持 UDP 分段卸载（GSO）；驱动首次使用时用系统 C 编译器把
  `_fastsend.c` 编译到 `~/.cache/dr47/`。没有编译器或设置 `DR47_FASTSEND=0` 时退回纯
  Python 发送（约 9 Gb/s）。
- 输入为 `interleaved_iq` 或 `packed_iq` 的 `int16`/`int32` 数组时不做额外拷贝；其他格式
  先由 numpy 转换，转换耗时计入上传时间。
- 所有发送线程共用一个 socket。每线程一个 socket 时网卡会把各队列的包逐帧交错，板卡每
  写一帧都要切换 DDR4 行，线速下丢帧约两成（靠补发仍能完成，但总耗时更长）。自行实现
  发送端时必须保证相邻数据报的地址基本连续。
- 接口 MTU 为 9000 时驱动自动改用 8192 bytes 的数据报；这一档只做过仿真，未上板验证。
- 批量会话期间 `DATA` 命令被拒绝；`COMMIT` 在图像不完整时返回 `INCOMPLETE`。

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
