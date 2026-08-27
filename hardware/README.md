 # FPGA 硬件设计

 本目录包含 Chisel 生成器、Vivado RTL/IP、约束和构建脚本。最终 bitstream、XSA
 和固件交付文件统一放在仓库根目录 artifacts/。

 ## 构建目标

 | 目标 | 用途 | XS20 |
 | --- | --- | --- |
 | custom_xczu47dr_master | 正常 RFDC 播放主卡 | 输出 SYNC |
 | custom_xczu47dr_slave | 正常 RFDC 播放从卡 | 输入 SYNC |
 | custom_xczu47dr_bw | DDR 带宽压力测试 | 不用于同步播放 |

 主线时钟为 XS17 外部 10 MHz，HMC7044 输出 128 MHz DAC 参考。XS18 是 Trigger
 输出，XS19 是 Trigger 输入。主从同步接线和验收项目见[硬件验收](../docs/硬件验收.md)。

 ## 构建

 ~~~bash
 source /tools/Xilinx/Vivado/2024.2/settings64.sh
 source /tools/Xilinx/Vitis/2024.2/settings64.sh

 make hardware TARGET=custom_xczu47dr_master
 make hardware TARGET=custom_xczu47dr_slave
 make bitstream-dual
 ~~~

 bitstream-dual 为主卡和从卡使用独立的 work-dual/、reports-dual/ 目录，避免
 Vivado 并行构建互相覆盖。生成的角色文件名为 custom_xczu47dr_master.* 和
 custom_xczu47dr_slave.*。

 ## 子目录

 - vivado/：顶层 RTL、UDP/RFCTRL2、RFDC 播放器、约束和 Vivado Tcl。
 - chisel/：可复用 Chisel 模块及 RFDC 配置生成器。
 - riscv-mini/：独立的 RISC-V 控制路径试验代码，当前由 PL shim 接入。

 Vivado 工程、综合实现报告、Chisel out/ 和 Vitis 工作区都是生成物，不应提交到
 版本库；清理使用 make clean，不要手工删除 artifacts/。
