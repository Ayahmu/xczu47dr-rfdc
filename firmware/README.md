# 裸机固件

固件运行在 XCZU47DR 的 Cortex-A53 裸机环境中，负责上电后的平台、HMC7044、RFDC、DAC MTS
和 NCO SYSREF 初始化。波形数据和运行时的 RFDC 参数由 PL 的 UDP 服务处理，PS 不运行网络协议栈。

## 构建和烧写

先加载 Vitis 2024.2：

~~~bash
source /tools/Xilinx/Vitis/2024.2/settings64.sh
~~~

从仓库根目录执行：

~~~bash
make firmware                                # ELF、FSBL 和 BOOT.BIN
JTAG_CABLE_SERIAL=<序列号> make program      # 经 JTAG 临时加载，掉电即失
JTAG_CABLE_SERIAL=<序列号> make flash        # 把 BOOT.BIN 写入 QSPI flash，上电自启动
JTAG_CABLE_SERIAL=<序列号> make boot-qspi    # 不动拨码，从 flash 重启一次以确认镜像
~~~

也可以在本目录运行 `./build.sh create|build|rebuild|program|download|bootbin|flash|boot-qspi|clean`。

- `program` 使用 `artifacts/` 中的 XSA（内嵌 bitstream 和 `psu_init.tcl`）与 ELF，两者必须来自
  同一次构建。
- `flash` 使用同一目录的 `BOOT.BIN`，它由 `bootbin` 把 Vitis 生成的 FSBL、PMU 固件和上面两个
  文件打在一起。固化流程和拨码要求见 [artifacts/README.md](../artifacts/README.md)。
- 发布到 `artifacts/` 的 ELF 去掉了符号和调试信息。调试时使用工程里未去符号的
  `workspace/custom_xczu47dr_waveform/rfdc_app/Debug/rfdc_app.elf`。

## 源码职责

~~~text
src/main.c                         启动流程和主循环
src/platform/                      平台、缓存和时钟初始化
src_custom/custom_xczu47dr/        定制板 RFDC 适配
scripts/create_app.tcl             创建 Vitis 工程
scripts/program.tcl                JTAG 下载 bitstream/ELF
scripts/boot_mode.tcl              经 JTAG 以指定启动模式（jtag/qspi）重启 PS
~~~

固件固定使用 XS17 外部 250 MHz 参考；HMC7044 内部 R1=25 后 PLL1 PFD 仍为 10 MHz。
固件只负责上电时的 RFDC 启动、DAC MTS 和 NCO 对齐；之后的配置、上传和播放都由 PL 完成。

## 启动检查

启动日志从 115200 波特率的串口输出，应依次看到 HMC7044 配置完成、RFDC PLL 就绪、DAC MTS
完成和 NCO SYSREF 就绪。串口只用于诊断；运行时的 RFDC 配置以驱动的 `status()` 回读为准。

~~~bash
screen /dev/ttyUSB0 115200
~~~
