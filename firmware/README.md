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
 make firmware
 JTAG_CABLE_SERIAL=<序列号> make program
 ~~~

 也可在本目录使用 ./build.sh create|build|rebuild|program|clean。program 使用
 artifacts/ 中的 XSA（内嵌 bitstream 和 psu_init.tcl）与 ELF，两者必须来自同一次构建。

 ## 源码职责

 ~~~text
 src/main.c                         启动流程和主循环
 src/platform/                      平台、缓存和时钟初始化
 src_custom/custom_xczu47dr/        定制板 RFDC 适配
 scripts/create_app.tcl             创建 Vitis 工程
 scripts/program.tcl                JTAG 下载 bitstream/ELF
 ~~~

 固件固定使用 XS17 外部 250 MHz 参考；HMC7044 内部 R1=25 后 PLL1 PFD 仍为 10 MHz。
 固件只负责上电时的 RFDC 启动、DAC MTS 和 NCO 对齐；之后的配置、上传和播放都由 PL 完成。
 启动日志通过
 115200 波特率串口查看；串口是诊断手段，不是运行时 RFDC 配置确认手段。

 ## 启动检查

 应看到 HMC7044 配置完成、RFDC PLL 就绪、DAC MTS 完成和 NCO SYSREF 就绪。

 ~~~bash
 screen /dev/ttyUSB0 115200
 ~~~
