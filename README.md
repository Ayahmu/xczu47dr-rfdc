# XCZU47DR RFDC 波形项目

这是一个面向定制 XCZU47DR 板卡的 FPGA、裸机固件和 Python 控制软件项目，支持
单板波形播放、双板同步和网页控制台。

## 从哪里开始

- [Slave 外部 Trigger 快速上手](快速上手_方案B.md)：当前唯一板级测试入口。
- [使用与测试指南](docs/使用与测试指南.md)：安装、网络、烧写、接线和第一次发波。
- [硬件验收](docs/硬件验收.md)：示波器/频谱仪项目和验收记录模板。
- [API 参考](docs/API参考.md)：Python 驱动、UDP 协议和命令行接口。
- [网页部署说明](software/网页部署说明.md)：部署 FastAPI + Vue 控制台。
- [TDC 实施记录](docs/TDC_项目评估与实施记录.md)：历史研发与验证记录，不是当前操作入口。

## 目录

```text
hardware/   Chisel、Vivado RTL、IP、约束和构建脚本
firmware/   ZynqMP 裸机启动程序和 JTAG 烧写脚本
software/    Python 驱动、波形工具和网页控制台
artifacts/  可直接烧写的 bitstream、XSA、ELF 和校验文件
tests/      驱动、协议、波形和构建回归测试
```

## 常用命令

```bash
# 已有 artifacts 时直接烧写
JTAG_CABLE_SERIAL=<序列号> TARGET=custom_xczu47dr_master make program

# 构建一个角色的硬件、XSA 和固件
make all TARGET=custom_xczu47dr_master
make all TARGET=custom_xczu47dr_slave

# 同时构建主卡和从卡 bitstream
make bitstream-dual

# 构建单板 bypass 外部 Trigger bitstream
make bitstream-slave-trigout

# 运行本地回归测试
PYTHONPATH=software .venv/bin/python -m unittest discover -s tests -p 'test_*.py' -q
```

正式 RFDC 目标是 `custom_xczu47dr_master` 和 `custom_xczu47dr_slave`；
`custom_xczu47dr_bw` 只用于 DDR 带宽压力测试。主从角色在综合时确定，软件不能
把 slave 变成 master。
