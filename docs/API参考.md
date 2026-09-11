# Python 驱动 API 参考

本文档只描述第三方程序应使用的稳定接口。当前版本为 `47dr-driver 0.1.0`，
Python >= 3.10，运行时依赖 `numpy>=1.23`。当前对外版本不包含 TDC API。

## 1. 快速示例

```python
import numpy as np
from dr47 import BurstSchedule, Dr47Device

iq = np.zeros(1024, dtype="<i2")
iq[0::2] = 12000

with Dr47Device(
    ip="10.50.0.101",
    udp_interface="enp1s0f0",
    udp_source_ip="10.50.0.10",
    batch_mode=True,
) as board:
    board.set_xy_target_frequency(1, 4.0)
    board.set_qc_on_off("xy", 1, "on")
    board.commit()
    playback = board.configure_playback(
        {1: iq},
        schedule=BurstSchedule(20.0, 1000.0, 3),
        wave_formats={1: "interleaved_iq"},
    )
    board.arm_playback(channel_mask=playback.channel_mask)
    board.trigger_playback()
    board.abort_playback()
```

硬件时间单位是 ns，RF 频率是 GHz，IQ 采样率是 400 MS/s。波形数组为小端
`int16` 交错 I/Q：`I0,Q0,I1,Q1,...`。

## 2. 连接和状态

### `Dr47Device`

```python
Dr47Device(
    ip="192.168.1.128", port=1234, timeout_s=5.0,
    udp_interface="", udp_source_ip="", retries=2,
    batch_mode=False, sync_role="slave", transport=None,
)
```

创建对象不会访问板卡；`connect()` 才会发送 HELLO 和 STATUS。

| 参数 | 说明 |
| --- | --- |
| `ip`, `port` | 板卡 UDP 地址，端口通常为 1234 |
| `udp_interface` | 指定实际 10G 网卡；多网卡主机建议填写 |
| `udp_source_ip` | 指定 socket 源地址；必须已配置在该网卡上 |
| `timeout_s`, `retries` | 单次等待时间和可重试请求次数 |
| `batch_mode` | `True` 时 RFDC/增益设置暂存到 `commit()` |
| `sync_role` | 本地期望值，bitstream 固化的角色不能被软件改变 |

```python
device.connect() -> int
device.close() -> None
device.status(refresh=True) -> DeviceStatus
device.connected -> bool
```

`with Dr47Device(...) as device` 会自动连接和关闭。 `status()` 返回最近一次板卡快照；
`refresh=False` 只读取本地缓存。

`connect(**kwargs) -> Dr47Device` 是创建并连接设备的便捷工厂，参数与
`Dr47Device` 相同；调用方负责在使用后 `close()`。

### 状态对象

`DeviceStatus` 字段：`connected`、`ip`、`port`、`state`、`capabilities`、`message`。

`DeviceCapabilities` 常用字段：

| 字段 | 含义 |
| --- | --- |
| `device_uid`, `build_profile`, `protocol_version` | 板卡身份和协议 |
| `rfdc_ready`, `dac_mts_ready`, `nco_sync_ready` | RFDC 播放前置状态 |
| `sync_role`, `sync_mode`, `sync_seen`, `sync_link_ready` | 同步状态 |
| `trigger_input_count` | XS19 输入事件计数 |
| `trigger_accepted_count` | 播放器接受的 Trigger 计数 |
| `trigger_output_count` | XS18 输出事件计数 |
| `playback_state` | `PlaybackState` 枚举 |

`PlaybackState` 的值为 `idle`、`armed`、`prepared`、`running`、`fault`。

## 3. 网络发现

```python
from dr47 import discover_boards, provision_board, connect_discovered

boards = discover_boards(
    interface="enp1s0f0",
    source_ip="169.254.250.11",
    source_cidr="169.254.250.11/16",
)
```

### `discover_boards(...) -> list[DiscoveredBoard]`

向 `broadcast_ip` 发送只读 `NETWORK_GET`。主要参数为 `interface`、`source_ip`、
`source_cidr`、`broadcast_ip`、`port`、`timeout_s` 和 `rounds`。发现身份是
`(device_uid, current_mac)`，不要只按 UID 选择板卡。

`DiscoveredBoard` 常用字段：`device_uid`、`current_ip`、`current_mac`、`port`、
`build_profile`、`revision`、`interface`、`source_ip`；`as_dict()` 返回可 JSON
序列化的字典。

### `provision_board(board, ip, mac=None, ...) -> ProvisionedBoard`

设置固定 IP/MAC，重启网络服务，并在新 IP 上验证身份。常用参数：`subnet_mask`、
`gateway`、`port`、`revision`、`known_boards`。配置前必须为不同板卡分配不同 IP 和
MAC，并使用返回值中的 `ip` 创建新连接。

### 其他网络方法

```python
prepare_interface(interface, source_cidr) -> None
connect_discovered(board, timeout_s=5.0, retries=2) -> Dr47Device
parse_ip_pool("10.50.0.101-10.50.0.120") -> list[str]
```

`prepare_interface()` 修改 Linux 网卡状态，需要 `CAP_NET_ADMIN`；原始 UDP 绑定通常
需要 `CAP_NET_RAW`。产品 CLI `dr47-network` 使用同一组接口。

## 4. RFDC 和通道

```python
device.set_xy_target_frequency(channel, target_rf_ghz, dac_fs_ghz=6.4) -> dict
device.set_xy_nco_frequency(channel, frequency_ghz) -> int
device.set_gain("xy", channel, gain=0.7, gain_type="norm") -> int
device.set_qc_on_off("xy", channel, "on") -> int
device.set_qr_on_off("xy", channel, "on") -> int
device.commit() -> int
```

- `set_xy_target_frequency()` 输入最终模拟频率，自动选择 NCO 和 Nyquist zone。例如
  4 GHz -> NCO `-2.4 GHz`、zone 2。
- `set_xy_nco_frequency()` 直接设置 RFDC NCO，当前范围为 `-3.2..+3.2 GHz`。
- `set_gain()` 的 `gain_type="norm"` 范围是 `0..1`，映射为 DAC 输出电流。
- `set_qc_on_off()` 控制输出通道；`set_qr_on_off()` 当前不支持 ADC/DAQ 输入。
- `batch_mode=True` 时，设置不会立即发送，必须调用 `commit()`。

`apply_rfdc_config(...)` 可一次提交多通道的 `nco_ghz`、`nyquist_zone`、`phase_deg`、
`output_current_ma`、`revision` 和 `channel_mask`。普通应用使用上面的通道方法更直观。

## 5. 波形和有限 burst

### 波形工具

```python
from dr47 import (
    make_iq_sine_interleaved,
    make_iq_gaussian_sine_interleaved,
    place_interleaved_iq_in_record,
    make_burst_record,
)
```

`make_iq_gaussian_sine_interleaved()` 的 `duration_s`、`fwhm_s`、`sample_rate_hz`
使用秒和 Hz；返回交错 `int16`。`place_interleaved_iq_in_record()` 将波形放入延迟和
零填充记录。`make_burst_record()` 创建单脉冲周期记录，适合手工构造 burst。

### `BurstSchedule`

```python
BurstSchedule(first_delay_ns, interval_ns, repetitions, debug_alternate=False)
```

含义分别是 Trigger 后首次延迟、波形起点到起点间隔、重复次数和调试交替模式。硬件
使用 50 MHz 调度时钟，时间会向上量化到 20 ns。 `schedule.quantized()` 返回实际的
`effective_first_delay_ns`、`effective_interval_ns`、`first_delay_cycles`、
`interval_cycles` 和 `repetitions`。

### `configure_playback(...) -> PlaybackConfig`

```python
device.configure_playback(
    channel_waves,
    schedule,
    *,
    wave_formats=None,
    channel_mask=None,
    bulk_upload=False,
    progress_callback=None,
    packet_pause_s=1e-5,
    packet_burst=8,
) -> PlaybackConfig
```

该方法只上传一份记录，记录尾部补零后由 FPGA 重复播放。 `channel_waves` 是
`{物理通道: 波形}`；`wave_formats` 支持 `interleaved_iq`、`iq_matrix`、
`packed_iq` 和 `z`。长记录建议 `bulk_upload=True`。

`PlaybackConfig` 字段为 `schedule`、`channel_mask`、`record_duration_ns` 和
`record_bytes_per_channel`。进度回调签名为 `progress_callback(sent_packets, total_packets)`；
开始时回调 `(0, total_packets)`，每个波形 UDP 包发送后更新一次。

### 播放控制

```python
device.arm_playback(channel_mask=None, run_id=None) -> int
device.trigger_playback() -> int
device.abort_playback() -> int
```

`arm_playback()` 进入等待状态；软件 Trigger 使用 `trigger_playback()`；测试结束和
异常清理使用 `abort_playback()`。旧名称 `arm()`、`trigger()`、`abort_mute()`
仍保留兼容，但新代码建议使用带 `_playback` 后缀的名称。

## 6. 同步和外部 Trigger

```python
device.set_sync_mode("external" | "bypass") -> int
device.bypass_sync() -> int
device.require_external_sync() -> int
device.sync(epoch=1) -> int
device.emit_trigger() -> int
```

- 单板 slave 没有 XS20 SYNC 时调用 `bypass_sync()`，然后 ARM 等待 XS19。
- 双板必须使用 `external`，不能用 bypass 代替同步。
- `sync()` 只允许固化角色为 master 的板卡发出 XS20 SYNC。
- `emit_trigger()` 只输出 XS18 脉冲，不等同于本地播放 Trigger。

双板严格同步使用：

```python
from dr47 import SyncGroup
result = SyncGroup(master, slave, timeout_s=5.0).sync(epoch=1)
```

`SyncAlignmentResult` 返回两侧 alignment epoch、SYNC 接收状态、MTS/NCO 就绪状态和耗时。
XS20、XS18、XS19 接线和参考时钟必须先满足[使用与测试指南](使用与测试指南.md)。

## 7. 模拟器

`SimulatedDr47Device` 继承高层播放 API，不创建 UDP socket，适合无硬件测试：

```python
from dr47 import SimulatedDr47Device

with SimulatedDr47Device(sync_role="master") as board:
    print(board.status(refresh=False).capabilities.device_uid)
```

模拟器不能验证网卡、DDR 吞吐、HMC7044、RFDC 或物理 Trigger 电平。

## 8. 异常

所有驱动异常继承 `DriverError`。常用类型：

| 异常 | 处理方向 |
| --- | --- |
| `TransportTimeout` / `ConnectionError` | 检查 IP、网卡、VLAN 和权限，可重试 |
| `ProtocolError` / `ProtocolVersionError` | 检查驱动和 bitstream 版本 |
| `DeviceBusyError` | 等待当前操作结束，不要重复配置 |
| `DeviceNotReadyError` | 等待 RFDC/MTS/NCO 状态就绪 |
| `SynchronizationError` / `SyncRequiredError` | 检查角色、模式和 XS20 |
| `ParameterRangeError` / `WaveformFormatError` | 修正参数或波形数组 |
| `DiscoveryError` / `ProvisionError` | 检查广播、地址冲突和新 IP 验证 |
| `UnsupportedCapabilityError` | 当前 bitstream 不具备该能力 |

安全清理模式：

```python
try:
    device.connect()
    # 配置、上传和播放
finally:
    if device.connected:
        device.abort_playback()
    device.close()
```

协议打包函数、UDP 地址布局和 `dr47.tdc` 不属于当前稳定交付 API。需要协议调试时
应直接阅读 `software/dr47/protocol.py`，不要在业务程序中依赖其内部字段。
