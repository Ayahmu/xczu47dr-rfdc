# dr47 Python 驱动

这是直接通过 UDP 控制单板 WAVECTR0/RFCTRL2 服务的驱动包。RFCTRL2 在这里仅表示板端封套和 RFDC/诊断服务，不表示旧播放入口。
安装和板级流程请看[软件版本说明](../../docs/软件版本说明.md)，完整接口请看
[API 接口参考](../../docs/API参考.md)。

当前版本的对外交付范围不包含 TDC 校准、补偿或诊断；发布 wheel 会移除
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

## 测试脚本

所有面向使用者的测试脚本都在 `examples/` 目录。配置是脚本顶部的常量（板卡 IP、主机网卡、
源 IP、通道、频率等），不读命令行参数或环境变量；改好常量后直接运行，结尾打印 `PASS` 或
`FAIL`。

| 脚本 | 用途 | 需要 |
|---|---|---|
| `waveform_software_play_example.py` | 发波：上传一包高斯脉冲到 CH1/CH2，发送软件 `PLAY` | 板卡、示波器 |
| `waveform_external_trigger_example.py` | 发波：上传后等待 XS19 外部 Trigger 启动 | 板卡、示波器、触发源 |
| `waveform_bulk_upload_speed_example.py` | 板上测速：经 100G 批量通路上传随机波形，报告速率、丢帧和补发，再完整播放一遍 | 板卡 |
| `waveform_100g_stress_example.py` | 100G 压测：按发送线程数分档持续灌数据，报告带宽、丢包率和丢包环节 | 板卡 |
| `network_discovery_example.py` | 广播发现板卡并读取网络配置 | 板卡 |
| `simulator_quickstart.py` | 用内存模拟器走一遍上传和播放，检查安装 | 无 |

~~~bash
python software/dr47/examples/waveform_bulk_upload_speed_example.py
python -m dr47.examples.simulator_quickstart          # 安装 wheel 后的写法
~~~

## 本地验证

~~~bash
python -m pip install -r software/requirements.txt
python -m pytest tests -q          # 或 make test；RTL 仿真需要 Vivado 在 PATH 中，否则自动跳过
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

不小于 1 MiB 的图像由 `upload_waveforms()` 自动改走批量通路：数据报不逐包应答，发往
控制端口 + 1，板卡以 512-bit 位宽直接写 DDR4，丢失的 1 MiB 分块由驱动查询后补发。
板上实测 8 通道整片 DDR4（8 GiB）0.75 s 传完，91.6 Gb/s。条件和限制见 API 接口参考
的“批量上传”一节。

`waveform_status()` 返回 session、descriptor、状态、错误码和首个错误 offset。
外部窄 Trigger 只在 `WAIT_TRIGGER` 消费；其他状态的 Trigger 丢弃且不排队。
