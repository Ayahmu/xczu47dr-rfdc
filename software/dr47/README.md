# dr47 Python 驱动

这是直接通过 UDP 控制单板 WAVECTR0/RFCTRL2 服务的驱动包，不依赖网页服务。RFCTRL2 在这里仅表示板端封套和 RFDC/诊断服务，不表示旧播放入口。
安装和板级流程请看[软件版本说明](../../docs/软件版本说明.md)，完整接口请看
[API 接口参考](../../docs/API参考.md)。

当前 `0.1.0` 对外交付范围不包含 TDC 校准、补偿或诊断；发布 wheel 会移除
`dr47.tdc`。仓库中保留的相关研发代码和底层寄存器入口不属于当前公共 API。

## 快速导入

~~~python
from dr47 import Dr47Device

with Dr47Device(
    ip="10.50.0.101", port=1234,
    udp_interface="enp1s0f0", udp_source_ip="10.50.0.10",
) as board:
    print(board.status())
~~~

高层频率单位是 GHz；RFDC 输入为 400 MS/s 复数 IQ。设置最终模拟频率时优先使用
`set_xy_target_frequency()`：例如 4 GHz 会自动映射为 NCO=-2.4 GHz、Nyquist
zone=2；上传的 IQ 只放低频包络。`set_xy_nco_frequency()` 仅用于直接设置
`-3.2..+3.2 GHz` 的 RFDC NCO。

## 板级测试入口

当前板级波形示例均使用单板 WAVECTR0，不依赖双板 SYNC、master/slave 角色或旧 ARM/TRIGGER
播放命令。外部 Trigger 示例上传 CH1/CH2 后等待 XS19；软件示例上传后发送一次 `PLAY`。
所有用户配置均为脚本顶部的直接常量，不读取命令行参数或环境变量。

~~~bash
.venv/bin/python software/dr47/examples/waveform_external_trigger_example.py
.venv/bin/python software/dr47/examples/waveform_software_play_example.py
~~~

`simulator_quickstart.py` 和 `network_discovery_example.py` 是不直接发射波形的 SDK 教学
样例。安装 wheel 后可用 `python -m dr47.examples.<模块名>` 运行。

## 本地验证

~~~bash
PYTHONPATH=software python -m unittest discover -s tests -p 'test_*.py' -q
~~~

## 统一单板波形播放

新链路只使用 `BEGIN → DATA → COMMIT → PREFETCH → WAIT_TRIGGER → PLAYING`。
8 个通道共享一个 `total_beats` 和交织 512-bit DDR 布局；DATA 分片必须按
`packet_seq`、`byte_offset` 连续到达，并通过 payload CRC。重复分片只返回当前确认，
不会重复写 DDR。`COMMIT` 成功后自动预取，不再使用 ARM/PREPARE。

```python
board.begin_waveform(session=1, total_bytes=len(image), channel_mask=0xff,
                     total_beats=len(image) // 256, loop_count=1)
for packet_seq, offset in enumerate(range(0, len(image), 1024)):
    board.data_waveform(session=1, packet_seq=packet_seq, byte_offset=offset,
                        payload=image[offset:offset + 1024])
board.commit_waveform(session=1)
board.play(session=1)       # WAIT_TRIGGER 立即启动；READY/DONE 先重新预取
board.pause(session=1)      # 停止门控并回到 READY
board.stop(session=1)
board.abort(session=1)      # 清除 descriptor/session，回到 IDLE
```

`waveform_status()` 返回 session、descriptor、状态、错误码和首个错误 offset。
外部窄 Trigger 只在 `WAIT_TRIGGER` 消费；其他状态的 Trigger 丢弃且不排队。
