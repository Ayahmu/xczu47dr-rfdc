# XCZU47DR RFDC 波形项目

本仓库包含 XCZU47DR FPGA 逻辑、裸机固件和 Python 驱动。当前分支使用 XS17
的 250 MHz 外部参考，支持 DDR 波形播放、主从同步，以及 slave bypass 模式下的
XS19 外部 Trigger。

## 文档入口

- [使用与测试指南](docs/使用与测试指南.md)：安装、烧写、网络和实板测试。
- [驱动 SDK 交付指南](docs/驱动SDK交付指南.md)：生成和使用对外安装包。
- [API 参考](docs/API参考.md)：稳定 Python 接口、单位、返回值和异常。
- [硬件验收](docs/硬件验收.md)：示波器和频谱仪验收项目。
- [网页部署说明](software/网页部署说明.md)：部署 FastAPI 和 Vue 控制台。

当前对外驱动不包含 TDC 接口。历史方案文档已从主文档体系移除，避免和当前
bitstream、脚本及操作流程混用。

## 目录

- `hardware/`：RTL、Vivado 脚本和约束。
- `firmware/`：ZynqMP 裸机 RFCTRL2 服务。
- `software/dr47/`：可安装的 Python 驱动和样例。
- `tests/`：软件、RTL 和构建回归。
- `artifacts/`：bitstream、XSA、ELF、LTX 和校验值。

## 常用命令

```bash
# 使用已有产物烧写 slave_trigout
JTAG_CABLE_SERIAL=<序列号> ./software/load_and_verify.sh slave_trigout

# 运行当前 slave 外部 Trigger 测试
.venv/bin/python software/dr47/examples/hardware_slave_bypass_external_trigger_test.py

# 运行回归或生成对外 SDK
make test
make driver-release
```

角色、接线和首次网络配置请先看[使用与测试指南](docs/使用与测试指南.md)。
