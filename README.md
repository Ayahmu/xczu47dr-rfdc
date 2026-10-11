# XCZU47DR RFDC 波形项目

本仓库包含 XCZU47DR 板卡的 FPGA 逻辑、裸机固件和 Python 驱动。板卡经 100G 网口接收
8 个通道的 IQ 波形，存入 8 GiB DDR4，由软件命令或 XS19 外部 Trigger 启动播放；参考时钟从
XS17 输入（交付版本为 250 MHz）。

## 文档

使用板卡和驱动：

- [软件使用说明](docs/软件版本说明.md)：安装驱动、发现板卡、运行示例，以及各版本的变更记录。
- [API 接口参考](docs/API参考.md)：每个接口的参数、返回值和错误，批量上传与 100G 压测的实测数据。
- [硬件指标](docs/硬件指标.md)：采样率、波形格式、Trigger 和网络接口特性。
- [硬件固件版本说明](docs/硬件固件版本说明.md)：硬件与固件的版本变更记录。

构建和烧写：

- [artifacts/README.md](artifacts/README.md)：可烧写文件、固化到 flash、JTAG 临时加载、启动拨码。
- [hardware/README.md](hardware/README.md)：FPGA 构建。
- [firmware/README.md](firmware/README.md)：固件构建和启动检查。
- [software/README.md](software/README.md)：驱动的开发环境、版本号和 SDK 打包。

## 目录

- `hardware/`：RTL、Vivado 脚本和约束。
- `firmware/`：ZynqMP 裸机 RFCTRL2 服务。
- `software/dr47/`：可安装的 Python 驱动；`software/dr47/examples/` 是全部示例和测试脚本。
- `tests/`：软件、RTL 和构建回归。
- `artifacts/`：XSA、ELF、启动镜像 BOOT.BIN 和校验值。

## 常用命令

```bash
# 把 artifacts/ 中的 XSA 和 ELF 经 JTAG 临时加载到板卡
JTAG_CABLE_SERIAL=<序列号> make program

# 把 artifacts/BOOT.BIN 固化到板载 flash（上电自启动），再从 flash 重启一次确认
JTAG_CABLE_SERIAL=<序列号> make flash
JTAG_CABLE_SERIAL=<序列号> make boot-qspi

# 示例脚本都在 software/dr47/examples/，改好文件顶部的常量后运行；清单见 software/dr47/README.md
python software/dr47/examples/waveform_software_play_example.py          # 发波
python software/dr47/examples/waveform_bulk_upload_speed_example.py     # 板上测速
python software/dr47/examples/waveform_100g_stress_example.py           # 100G 压测

# 运行回归或生成对外 SDK（二进制 wheel，需要 Docker）
make test
make driver-release
```

`make program` 和 `make flash` 需要先加载 Vitis 2024.2 的环境。安装驱动、接线和首次网络配置见
[软件使用说明](docs/软件版本说明.md)。
