# dr47 Python 驱动

`dr47` 通过 UDP 控制 47DR 板卡：发现和配置板卡、设置 RFDC 频率和通道、上传波形并启动播放。
安装和第一次使用的步骤见[软件使用说明](../../docs/软件版本说明.md)，完整接口见
[API 接口参考](../../docs/API参考.md)。

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
| `waveform_100g_stress_example.py` | 100G 压测：把链路打满持续灌数据，报告带宽、丢包率和丢包环节（判据：一帧不丢），并生成一份 HTML 报告 | 板卡 |
| `network_discovery_example.py` | 广播发现板卡并读取网络配置 | 板卡 |
| `simulator_quickstart.py` | 用内存模拟器走一遍上传和播放，检查安装 | 无 |

~~~bash
python examples/waveform_bulk_upload_speed_example.py     # SDK 目录下的脚本，改好顶部常量后运行
python -m dr47.examples.simulator_quickstart               # 随驱动安装的同一批脚本
~~~

## 波形上传和播放

`upload_waveforms()` 把各通道的波形打包上传并提交，板卡随后自动预取，准备好后进入
`WAIT_TRIGGER`，由软件 `PLAY` 或 XS19 外部 Trigger 启动：

```python
uploaded = board.upload_waveforms({1: wave_ch1, 2: wave_ch2}, loop_count=1)
session = int(uploaded["session"])
board.play(session=session)       # 立即启动；已播完或已停止时先重新预取
board.pause(session=session)      # 停止输出，回到 READY，波形保留
board.stop(session=session)
board.abort(session=session)      # 清除波形和错误，回到 IDLE
print(board.waveform_status(session=session))
```

不小于 1 MiB 的图像由 `upload_waveforms()` 自动改走批量通路：数据报不逐包应答，发往
控制端口 + 1，板卡以 512-bit 位宽直接写 DDR4，丢失的 1 MiB 分块由驱动查询后补发。
板上实测 8 通道整片 DDR4（8 GiB）0.75 s 传完，91.6 Gb/s。条件和限制见 API 接口参考
的“批量上传”一节。

`waveform_status()` 返回当前状态、播放位置、错误码以及 underflow 和 Trigger 计数。外部 Trigger
只在 `WAIT_TRIGGER` 状态被接受，其他时刻到达的事件丢弃且不排队。
