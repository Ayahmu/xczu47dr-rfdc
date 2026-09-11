# dr47 Python 驱动

这是直接通过 UDP 控制 FPGA 中 RFCTRL2 服务的驱动包，不依赖网页服务。
安装和板级流程请看[使用与测试指南](../../docs/使用与测试指南.md)，完整接口请看
[API 参考](../../docs/API参考.md)。

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

当前只保留 `examples/hardware_slave_bypass_external_trigger_test.py`。它将 slave
设置为 `bypass`，跳过 XS20 SYNC 门控，然后 ARM CH1/CH2 并等待进入 XS19 的外部
Trigger。脚本不会调用软件 `trigger()`，也不会从 XS18 输出 Trigger。

所有用户配置均为脚本顶部的直接常量，不读取命令行参数或环境变量。修改配置后运行：

~~~bash
.venv/bin/python software/dr47/examples/hardware_slave_bypass_external_trigger_test.py
~~~

`examples/` 还包含三个 SDK 教学样例：`simulator_quickstart.py`、
`network_discovery_example.py` 和 `single_board_software_trigger_example.py`。
安装 wheel 后可用 `python -m dr47.examples.<模块名>` 直接运行。

对外 SDK 交付请先阅读 [47DR 驱动 SDK 交付指南](../../docs/驱动SDK交付指南.md)；
运行 `make driver-release` 会在 `dist/` 生成 wheel 和包含文档/样例的 ZIP 包。

## 本地验证

~~~bash
PYTHONPATH=software python -m unittest discover -s tests -p 'test_*.py' -q
~~~

## 单份 DDR Burst 播放

驱动提供 `BurstSchedule(first_delay_ns, interval_ns, repetitions,
debug_alternate=False)`。时间按 DAC 50 MHz fabric 时钟向上量化到 20 ns。
DDR 只上传一份“波形 + 周期尾部零填充”记录，重复次数由 FPGA 的
`CMD_REPEAT` 完成；debug 交替模式按 ARM 会话跳过奇数次 Trigger。
