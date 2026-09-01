 # dr47 Python 驱动

 这是直接通过 UDP 控制 FPGA 中 RFCTRL2 服务的驱动包，不依赖网页服务。
 安装和板级流程请看[使用与测试指南](../../docs/使用与测试指南.md)，完整接口请看
 [API 参考](../../docs/API参考.md)。

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

 ## 正式板级入口

 ~~~text
 examples/hardware_slave_wait_sync_trigger_test.py       正式从卡：等待 SYNC 后上传并等待 XS19 Trigger
 examples/hardware_master_slave_sync_trigger_test.py     正式主从：主卡 SYNC/Trigger 驱动双板
 examples/hardware_slave_bypass_trigger_test.py          单块从卡 bypass：软件或 XS19 Trigger
 ~~~

这些脚本负责发现板卡、配置波形、ARM、Trigger 和清理；驱动模块本身不再兼任测试
脚本库。双板的 XS20 用于 SYNC，XS18 输出 Trigger，XS19 接收 Trigger。

`hardware_slave_wait_sync_trigger_test.py` 使用有限波形（`loop=False`）：一次 XS19
Trigger 只播放一条记录，FPGA 播放结束后自动从同一 DDR 记录预取并重新进入
`PREPARED`，因此不需要再次上传或 ARM。下一次 Trigger 必须等板卡重新 PREPARED；
如果外部 Trigger 间隔过短，脚本会报告输入计数大于接受计数。

三个正式入口都负责发现/配置网络、连接板卡、上传有限波形和清理。主从入口由
`SyncGroup.sync()` 发送一次 SYNC；从卡入口只等待外部 SYNC；bypass 入口明确跳过
XS20 门控。旧的重复示例已经删除，避免把 `loop=True` 误当成“每个 Trigger 一条波形”。

 ## 本地验证

 ~~~bash
 PYTHONPATH=software python -m unittest discover -s tests -p 'test_*.py' -q
 ~~~
