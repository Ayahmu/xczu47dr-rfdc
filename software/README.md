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

`dr47/examples/` 目前只保留一个测试脚本：从卡跳过 XS20 SYNC 门控，等待
XS19 外部 Trigger，并同时播放 CH1/CH2。板卡 IP、主机网卡、源 IP、频率、
脉冲和 Trigger 数量都直接写在脚本顶部，不接受命令行参数或环境变量。

~~~bash
.venv/bin/python software/dr47/examples/hardware_slave_bypass_external_trigger_test.py
~~~

## 常用工具

- `send_waveform_udp.py`：生成并上传 CH1-CH8 波形。
- `sync_two_boards.py`：双板 SYNC/Trigger 编排。
- `dr47-network`：发现、配置和查询板卡。
- `webapp/`：FastAPI 后端；`webui/`：Vue 前端。

网页控制台当前一次只控制一块板。

## SDK 交付

交付指南、API 参考、模拟器样例和上板样例见
[47DR 驱动 SDK 交付指南](../docs/驱动SDK交付指南.md)。在仓库根目录生成可发布包：

~~~bash
make driver-release
~~~
