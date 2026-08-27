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
 examples/hardware_master_slave_wave_test.py              双板同步
 examples/hardware_master_slave_gaussian_sine_test.py     交换机双板高斯正弦
 ~~~

 这些脚本负责发现板卡、配置波形、ARM、Trigger 和清理；驱动模块本身不再兼任测试
 脚本库。双板的 XS20 用于 SYNC，XS18 输出 Trigger，XS19 接收 Trigger。

 ## 本地验证

 ~~~bash
 PYTHONPATH=software python -m unittest discover -s tests -p 'test_*.py' -q
 ~~~
