 # 裸机固件

 固件运行在 XCZU47DR 的 Cortex-A53 裸机环境中。它负责上电后的平台、HMC7044、
 RFDC、DAC MTS 和 NCO SYSREF 初始化；波形数据和运行时 RFDC 参数由 PL 的 UDP
 服务处理，PS 不再运行 Ethernet/lwIP 服务。

 ## 构建和烧写

 先加载 Vitis 2024.2：

 ~~~bash
 source /tools/Xilinx/Vitis/2024.2/settings64.sh
 ~~~

 从仓库根目录执行：

 ~~~bash
 make firmware TARGET=custom_xczu47dr_master
 make firmware TARGET=custom_xczu47dr_slave
 JTAG_CABLE_SERIAL=<序列号> TARGET=custom_xczu47dr_slave make program
 ~~~

 也可在本目录使用 ./build.sh create|build|rebuild|program|clean。program 使用
 artifacts/ 中与目标同名的 bitstream、XSA、ELF 和 psu_init.tcl，主从文件不能混用。

 ## 源码职责

 ~~~text
 src/main.c                         启动流程和主循环
 src/platform/                      平台、缓存和时钟初始化
 src_custom/custom_xczu47dr/        定制板 RFDC 适配
 scripts/create_app.tcl             创建 Vitis 工程
 scripts/program.tcl                JTAG 下载 bitstream/ELF
 ~~~

 主卡和从卡共用一套 C 源码，只由对应 XSA 和构建目标决定 XS20 方向。启动日志通过
 115200 波特率串口查看；串口是诊断手段，不是运行时 RFDC 配置确认手段。

 ## 启动检查

 应看到 HMC7044 配置完成、RFDC PLL 就绪、DAC MTS 完成和 NCO SYSREF 就绪。固件只
 等待 HMC7044 PL 时序器，不等待 XS20；双板同步由主机驱动在板卡启动后完成。

 ~~~bash
 screen /dev/ttyUSB0 115200
 ~~~
