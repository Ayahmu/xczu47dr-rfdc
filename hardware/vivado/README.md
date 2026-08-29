 # Vivado 硬件构建

 这里是 XCZU47DR 的 Vivado 输入：src/ 放 RTL，bd/ 放 Block Design，ip/ 放
 固定 IP，xdc/ 放引脚和时序约束，scripts/ 放自动化流程。工程和报告只在本地
 生成，交付文件写入根目录 artifacts/。

 ## 目标和关键接口

 - custom_xczu47dr_master：XS20 为输出。
 - custom_xczu47dr_slave：XS20 为输入。
 - custom_xczu47dr_bw：独立带宽测试顶层，不包含正常 RFDC 播放角色。
 - XS18 (TRIG_1) 为 Trigger 输出，XS19 (TRIG_2) 为 Trigger 输入。
 - RFDC 为 6.4 GS/s、16 倍插值、400 MS/s IQ、50 MHz AXIS。
 - XS17 提供两板共同 10 MHz 参考；HMC7044 输出约 96 MHz `PL_CLK` 作为 SYNC/Trigger
   事件时间基准，PS `pl_clk` 不参与物理事件捕获。

 主从方向是综合时固定的宏定义，软件不能切换。主从接线和仪器检查见
 [硬件验收](../../docs/硬件验收.md)。

 ## 构建命令

 ~~~bash
 source /tools/Xilinx/Vivado/2024.2/settings64.sh

 make vivado-project TARGET=custom_xczu47dr_slave
 make preflight TARGET=custom_xczu47dr_slave
 make synth TARGET=custom_xczu47dr_slave
 make impl TARGET=custom_xczu47dr_slave
 make bitstream TARGET=custom_xczu47dr_slave
 make xsa TARGET=custom_xczu47dr_slave
 ~~~

 双板一次构建：

 ~~~bash
 make bitstream-dual
 make bitstream-dual-clean       # 只清理双板生成的工程和报告
 ~~~

 每个目标的输出都使用角色前缀，随后由 make firmware 生成匹配 ELF。不要把主卡
 bitstream 与从卡 XSA/ELF 混搭。

 ## 调试重点

 实现后先看时序报告中的 WNS/TNS、WHS/THS，再用 ILA 检查 UDP 接收、DDR 512 位
 交错数据、8 路打包器和 RFDC AXIS。Vivado DRC 警告需要按规则逐项判断，不能把所有
 警告都当成时序失败。

 `ila_hmc_event` 观察 HMC `PL_CLK` 域的 `sync_xs20_in/out`、`sync_hmc`、XS18/XS19
 Trigger、`hmc_event_tick`、`sync_event_tick`、`trigger_capture_tick` 和
 `trigger_launch_tick`。它与 `ila_dac_axis` 配合使用，才能区分物理事件时刻和 DAC
 AXIS 数据有效时刻。
