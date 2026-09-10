# Slave 外部 Trigger 快速上手

本文只描述当前仓库保留的单板测试入口：slave 跳过 XS20 SYNC，
等待 XS19 外部 Trigger，并让 CH1/CH2 同时播放有限高斯脉冲串。

历史的“方案 B”和 TDC 实验文档仍保留作为设计记录，但其中部分
脚本入口和命令已删除，不能作为当前操作流程。

## 1. 烧写当前 bitstream

单板 bypass 外部触发测试使用：

```text
artifacts/custom_xczu47dr_slave_trigout.bit
artifacts/custom_xczu47dr_slave.elf
```

这个 bitstream 需要包含提交 `03bfa12` 或更新版本的有限 burst 修复，
否则一次 Trigger 可能会无限循环播放。仓库已提交的
`custom_xczu47dr_slave_trigout.bit` 已包含该修复。

从仓库根目录执行：

```bash
JTAG_CABLE_SERIAL=<序列号> ./software/load_and_verify.sh slave_trigout
```

需要重新生成 bitstream 时执行：

```bash
make bitstream-slave-trigout
```

## 2. 连接硬件

```text
XS17 <- 250 MHz 参考时钟
外部 Trigger 源 -> XS19
XS20 断开
CH1、CH2 -> 示波器或 50 ohm 负载
```

外部 Trigger 间隔必须大于一整组脉冲播放和播放器重新进入
`PREPARED` 所需的时间。脚本发现 XS19 输入计数大于接受计数时会直接
报错，这表示外部 Trigger 过快且事件没有排队。

## 3. 修改测试参数

打开：

```text
software/dr47/examples/hardware_slave_bypass_external_trigger_test.py
```

直接修改文件顶部“用户配置”区域。该脚本不接受命令行参数，也不读取
环境变量。常用参数：

| 常量 | 作用 |
| --- | --- |
| `BOARD_IP` | 板卡 IP |
| `UDP_INTERFACE` / `UDP_SOURCE_IP` | 主机 10G 网口和源 IP |
| `OUTPUT_CHANNELS` | 输出通道，默认 CH1/CH2 |
| `RF_FREQUENCY_GHZ` | 目标射频 |
| `GAUSSIAN_DURATION_NS` | 单脉冲有限时间窗 |
| `GAUSSIAN_FWHM_NS` | 高斯包络半高全宽 |
| `FIRST_DELAY_NS` | Trigger 到第一个脉冲的延迟 |
| `PULSE_INTERVAL_NS` | 相邻脉冲起点间隔 |
| `PULSES_PER_TRIGGER` | 每次 Trigger 播放的脉冲数 |
| `TRIGGER_COUNT` | 本轮需要接受的外部 Trigger 数 |

`FIRST_DELAY_NS` 和 `PULSE_INTERVAL_NS` 会按 50 MHz DAC fabric 时钟向上
量化到 20 ns。DDR 只上传一份单脉冲记录，`PULSES_PER_TRIGGER` 由
FPGA 的有限重复调度完成。

## 4. 运行测试

```bash
.venv/bin/python software/dr47/examples/hardware_slave_bypass_external_trigger_test.py
```

正常输出会依次显示连接、bypass、CH1/CH2 配置、波形上传和 ARM，
然后在 XS19 计数变化时打印：

```text
XS19: 输入=1, 接受=1, 目标=10000
```

完成后应看到 `PASS`，且 XS19 输入数、接受数与 `TRIGGER_COUNT`
一致，XS18 输出数为 0。脚本退出时会停止并静音播放器。

## 5. 结果验收

驱动脚本通过只能说明 UDP、状态机、外部 Trigger 计数和有限 burst
链路走通。频率、幅度、脉冲数量、间隔和触发抖动必须用示波器或频谱仪
验收。

更完整的安装、网络和烧写流程见 [使用与测试指南](docs/使用与测试指南.md)，
仪器验收项见 [硬件验收](docs/硬件验收.md)。
