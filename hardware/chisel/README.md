 # Chisel 硬件生成器

 Chisel 源码用于生成可综合 Verilog 和 RFDC Vivado 配置 Tcl。Vivado 顶层和 UDP
 协议代码不在这里维护，统一位于 hardware/vivado/。

 ## 环境

 - Mill 0.11.6
 - Java 8 或更高版本
 - Scala 由 Mill 自动管理

 ## 常用命令

 ~~~bash
 ./build.sh all       # 生成全部模块和 RFDC 配置
 ./build.sh rfdc      # 只生成 RFDC 配置 Tcl
 ./build.sh led
 ./build.sh gpio
 ./build.sh reset
 ./build.sh glue
 ./build.sh clean
 ~~~

 生成物位于 generated/，Mill 的 out/ 是缓存目录，均不应作为手工源码修改。

 ## 模块目录

 common/ 是 AXI、连接、FIFO、存储和数学工具；led/、gpio/、reset/、glue/
 是基础外设；rfdc/ 生成定制 XCZU47DR 的 RFDC 参数；axidma/ 和 memory/
 保留给对应实验模块。公共模块的接口和测试代码直接看各自 src/、tb/ 文件，
 不再维护重复的子目录说明文档。
