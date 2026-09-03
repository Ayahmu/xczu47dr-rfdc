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

 高层频率单位是 GHz；RFDC 输入为 400 MS/s 复数 IQ。高于 200 MHz 的射频载波通常
 由 NCO 产生，上传的 IQ 只放低频包络。

 ## 正式板级入口

 ~~~text
 examples/hardware_master_standalone_wave_test.py         单板主卡
 examples/hardware_slave_bypass_software_trigger_test.py 单板从卡旁路
 examples/hardware_slave_external_trigger_test.py         从卡真实 SYNC/Trigger
 examples/hardware_slave_wait_sync_trigger_test.py       从卡等待 SYNC 后上传并等待 XS19 Trigger
examples/hardware_dual_slave_external_trigger_test.py    两块从卡等待外部 SYNC/Trigger
examples/hardware_master_slave_wave_test.py              双板同步
 examples/hardware_master_slave_gaussian_sine_test.py     交换机双板高斯正弦
 ~~~

这些脚本负责发现板卡、配置波形、ARM、Trigger 和清理；驱动模块本身不再兼任测试
脚本库。双板的 XS20 用于 SYNC，XS18 输出 Trigger，XS19 接收 Trigger。

`hardware_slave_wait_sync_trigger_test.py` 使用有限波形（`loop=False`）：一次 XS19
Trigger 只播放一条记录，FPGA 播放结束后自动从同一 DDR 记录预取并重新进入
`PREPARED`，因此不需要再次上传或 ARM。下一次 Trigger 必须等板卡重新 PREPARED；
如果外部 Trigger 间隔过短，脚本会报告输入计数大于接受计数。

其中 `hardware_dual_slave_external_trigger_test.py` 专门用于两块都是 slave 的场景：
两块板分别等待外部 XS20 SYNC，成功后各自上传波形并 ARM，最后同时等待外部设备
通过各自 XS19 输入 Trigger。它不会调用 `sync()`、`trigger()`、`emit_trigger()`
或 `bypass_sync()`，所以必须先接好外部同步和触发源；运行前要在脚本顶部填写两块
slave 的 UID/MAC 和目标 IP。

 ## 本地验证

 ~~~bash
 PYTHONPATH=software python -m unittest discover -s tests -p 'test_*.py' -q
 ~~~
