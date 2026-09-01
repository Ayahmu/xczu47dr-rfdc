 # 主机软件

 本目录提供 Python 驱动、波形生成工具和网页控制台。完整操作流程请看
 [使用与测试指南](../docs/使用与测试指南.md)，函数和协议请看[API 参考](../docs/API参考.md)。

 ## 安装

 ~~~bash
 python3 -m venv .venv
 source .venv/bin/activate
 python -m pip install -r software/requirements.txt
 python -m pip install -e software/dr47
 ~~~

 ## 板级测试入口

 正式脚本全部位于 dr47/examples/，网络参数直接写在脚本顶部：

 ~~~bash
 PYTHONPATH=software python -m dr47.examples.hardware_slave_wait_sync_trigger_test
 PYTHONPATH=software python -m dr47.examples.hardware_master_slave_sync_trigger_test
 PYTHONPATH=software python -m dr47.examples.hardware_slave_bypass_trigger_test
 ~~~

 双板交换机测试使用一个主机 10G 口：主机和两板在同一 Access VLAN，先配置
 169.254.250.11/16 发现地址，再为两块板分配不同的正式 IP。每次重新烧写后都要
 重新发现和验证网络。

 ## 常用工具

 - send_waveform_udp.py：生成并上传 CH1-CH8 波形。
 - sync_two_boards.py：双板 SYNC/Trigger 编排。
 - dr47-network：发现、配置和查询板卡。
 - webapp/：FastAPI 后端；webui/：Vue 前端。

 网页控制台当前一次只控制一块板，双板同步请使用 dr47.examples 脚本。
