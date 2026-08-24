# 47DR 驱动测试说明

本文把“真正访问板卡的驱动测试”和“本地协议/仿真测试”分开。三个板级脚本都
先广播发现板卡、读取 bitstream 主从角色、按照脚本顶部常量分配目标 IP 并验证，
然后才连接并发波。它们不接收网络命令行参数；运行前直接修改脚本顶部的网卡、
发现源地址、目标 IP、可选 `device_uid` 和可选 MAC。

## 三个正式发波入口

| 测试文件 | 是否上板 | 需要的 bitstream/接线 | 主要验证 | 不证明什么 |
| --- | --- | --- | --- | --- |
| `hardware_master_slave_wave_test.py` | 是，两块板 | 主卡 + 从卡；两块 XS17 接同一参考时钟；主 XS20 -> 从 XS20；主 XS18 -> 从 XS19 | external 模式下主卡发 SYNC，从卡 `sync_seen`/`sync_link_ready` 变真；主卡本地 UDP 发波；主卡物理 Trigger 触发从卡 | 不给出 RF 相位、频率、幅度或同步抖动的仪器结论 |
| `hardware_master_standalone_wave_test.py` | 是，一块板 | 正式主卡；XS17 接参考时钟；XS20、XS18、XS19 可悬空 | 主卡不调用 `sync()`，直接配置、ARM、UDP `trigger()` 进入 RUNNING | 不验证 XS20 实际输出脉冲，也不验证 XS18 电缆回环 |
| `hardware_slave_bypass_software_trigger_test.py` | 是，一块板 | 正式从卡；XS17 接参考时钟；XS20 悬空；不需要 XS18 -> XS19 | 从卡 `bypass_sync()` 后，仅由 UDP `trigger()` 自己发波；`sync_seen` 仍为 False；物理 Trigger 计数不被软件 Trigger 改变 | 不证明板卡与外部时钟/主卡已经同步，也不测 RF 输出 |

运行命令（在仓库根目录）：

```bash
PYTHONPATH=software python -m dr47.hardware_master_slave_wave_test
PYTHONPATH=software python -m dr47.hardware_master_standalone_wave_test
PYTHONPATH=software python -m dr47.hardware_slave_bypass_software_trigger_test
```

三者都执行 `finally -> abort_mute()`，测试失败时也会尽力停止输出。成功只代表
数字控制和播放状态机走通；示波器或频谱仪必须另外接到实际 DAC 输出端，确认
载波频率、幅度、脉冲宽度和相位关系。

`device_uid` 留空时，单卡脚本自动选择唯一的目标角色；双卡脚本分别选择唯一主卡
和唯一从卡。如果交换机后存在多块同角色板卡，必须在脚本顶部填写目标 UID，脚本
不会根据发现顺序猜测。默认目标地址仍位于 `169.254.0.0/16`。若改为
`10.50.0.x/24`，主机网卡必须预先配置该网段地址，并同时修改脚本中的
`CONTROL_SOURCE_IP` 和 `TARGET_SUBNET_MASK`。

## 驱动模拟/协议单元测试

`tests/test_dr47_driver.py` 是驱动层本地回归测试，不访问真实板卡。文件中的测试
按以下功能覆盖：

| 测试组 | 覆盖内容 |
| --- | --- |
| RFCTRL2 与 transport | 小端字节布局、请求重试、序号过滤、广播多响应收集 |
| 网络记录 | IP 地址池解析、发现板卡记录序列化、按角色/UID选择和目标 IP 配置编排 |
| 播放数据 | CH1-CH8 交织布局、上传包与网页手动发波 wire contract |
| 模拟状态机 | ARM/Trigger/ABORT、主卡本地运行、从卡 external 门控、bypass 回环、角色不可运行时修改 |
| 频率与波形工具 | GHz -> 整数 Hz 转换、NCO/Nyquist 计划、ns -> IQ 样点、高斯/正弦波形和 Trigger 序列 |
| 兼容性 | `self_test` 旧名称产生弃用警告并映射到 `bypass` |

运行：

```bash
PYTHONPATH=software python -m unittest tests.test_dr47_driver -q
```

这些测试通过不能替代板级测试；它们不会发现 HMC7044 参考时钟错误、XDC 方向
错误、XS20 电平问题、电缆断路、RFDC 校准失败或示波器上的频率偏差。

## 仓库其余测试分类

以下测试服务于驱动依赖的其他层，属于本地测试，不是上述三类发波脚本：

| 文件 | 分类和用途 |
| --- | --- |
| `test_rfdc_pl_protocol.py`、`test_host_udp_waveform.py`、`test_send_waveform_udp.py`、`test_golden_pattern_udp.py` | UDP/RFCTRL2 包、主机发送和数据布局 |
| `test_sync_two_boards.py` | 双板同步编排的模拟/桩测试 |
| `test_hmc7044_config.py`、`test_hmc7044_rtl_sim.py` | HMC7044 配置文本和 RTL 仿真 |
| `test_rtl_sim.py`、`test_*` 中的 `tb_*.sv` | Chisel/RTL 控制器、FIFO、Trigger、waveform executor 仿真 |
| `test_waveform_model.py`、`test_waveform_tools.py`、`test_extreme_length_config.py` | 波形模型、编码工具和边界长度 |
| `test_vivado_build_options.py`、`test_vivado_fifo_config.py` | Vivado 构建参数和 FIFO 约束 |
| `test_ila_capture_report.py` | ILA 报告解析 |
| `test_webapp_api.py`、`test_webapp_management.py`、`test_webapp_network.py`、`test_webapp_waveforms.py` | 网页端 API、管理、网络和波形接口 |

## 推荐验收顺序

单板从卡只想验证“跳过同步后自己发波”时，先运行
`hardware_slave_bypass_software_trigger_test.py`。主卡单板使用
`hardware_master_standalone_wave_test.py`。只有在主卡、从卡和两条连接线都准备好后，才运行
`hardware_master_slave_wave_test.py`。最后用仪器记录 RF 结果；驱动日志中的
`RUNNING`、`sync_seen` 和 Trigger 计数只能作为数字路径证据。
