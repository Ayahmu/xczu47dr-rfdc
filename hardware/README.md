# FPGA 硬件设计

本目录包含 Chisel 生成器、Vivado RTL/IP、约束和构建脚本。XSA（内嵌 bitstream）和
固件 ELF 统一写入仓库根目录 `artifacts/`。

## 构建目标

只有一个产品目标 `custom_xczu47dr_waveform`：单板波形播放，100G QSFP28 网口，
XS18 为 Trigger 输出，XS19 为 Trigger 输入。XS17 外部参考可选 250 MHz（默认）或
10 MHz，由构建参数 `REFERENCE_MHZ` 决定 HMC7044 的 R1 分频，其余时钟完全相同。

## 构建

~~~bash
source /tools/Xilinx/Vivado/2024.2/settings64.sh
source /tools/Xilinx/Vitis/2024.2/settings64.sh

make hardware                 # 250 MHz 参考，约 70 分钟，写入 artifacts/
make hardware REFERENCE_MHZ=10
make hardware-both            # 两种参考并行构建，分别写入 artifacts/10mhz 和 artifacts/250mhz
make firmware                 # 用当前 XSA 重建固件 ELF
~~~

构建结束时会检查时序报告，约束不满足则失败。

## 子目录

- `vivado/`：顶层 RTL、UDP/RFCTRL2、波形上传与回放、约束和 Vivado Tcl。
- `chisel/`：RFDC、DDR4 等 IP 配置和小模块的 Chisel 生成器。

Vivado 工程、综合实现报告、Chisel `out/` 和 Vitis 工作区都是生成物，不进版本库；
清理使用 `make clean`。
