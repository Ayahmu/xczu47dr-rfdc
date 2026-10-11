# 可烧写文件

本目录对应 XS17=250 MHz 参考、100G QSFP28 网口的单板波形产品。`artifacts/` 是
`make program` 和 `make flash` 的唯一输入目录；这里的文件是构建后的交付物，不是源码。修改
硬件或固件后应由构建命令重新生成，并和对应源码一起提交。

## 文件

~~~text
custom_xczu47dr_waveform.xsa        硬件平台（内含 *.tmp.bit、psu_init.tcl、build_manifest.json）
custom_xczu47dr_waveform.elf        PS 固件
BOOT.BIN                            启动镜像：FSBL + PMU 固件 + bitstream + PS 固件
custom_xczu47dr_waveform_fsbl.elf   FSBL；写 flash 时由烧写工具用来初始化 PS
SHA256SUMS                          上述文件的校验和
~~~

bitstream 只以 XSA 内嵌形式交付，烧写脚本会自动提取。`build_manifest.json` 记录构建
所用的源码提交（`source_commit`）以及构建时工作区是否有未提交改动（`source_dirty`）；
板卡 STATUS 返回的 `source_commit_id` 与其中的 `source_commit` 一致。

两个 ELF 都去掉了符号表和调试信息（其中有全部源文件名和构建路径）。调试时用 Vitis 工程里
未去符号的文件：`firmware/workspace/custom_xczu47dr_waveform/rfdc_app/Debug/rfdc_app.elf`。

`BOOT.BIN` 由 `make firmware` 随 ELF 一起生成；`make hardware` 导出新的 XSA 时会删掉旧的
`BOOT.BIN` 和 FSBL，重新 `make firmware` 后才会再有。

校验现有文件：

~~~bash
(cd artifacts && sha256sum -c SHA256SUMS)
~~~

## 固化到板载 flash（上电自启动）

交付给用户的板卡从 QSPI flash 启动，不需要 JTAG、XSA 或 Xilinx 工具：

~~~bash
source /tools/Xilinx/Vitis/2024.2/settings64.sh
JTAG_CABLE_SERIAL=<序列号> make flash        # 擦除、写入并校验，约 11 分钟
JTAG_CABLE_SERIAL=<序列号> make boot-qspi    # 不动拨码，经 JTAG 让板卡从 flash 重启一次
~~~

- flash 是两片 N25Q512A 双片并行（共 128 MiB），`BOOT.BIN` 约 35 MiB，写在偏移 0。
- `make boot-qspi` 用 PS 的备用启动模式寄存器让 BootROM 走一遍 flash 启动，用来在出厂前
  确认镜像；从复位到驱动可以连接、RF 就绪约 5–8 s。
- 板卡要在上电时自己启动，启动模式拨码 S2 必须拨到 QSPI32（模式值 2）：第 2 位 OFF，
  第 1、3、4 位 ON。S2 的第 1–4 位依次是 PS_MODE0–3，ON 为 0、OFF 为 1；四位全 ON 是
  JTAG 模式，上电不会加载任何东西。
- 拨码只在上电复位时采样，改动后要重新上电或按一下复位键 SW3 才生效。`make flash`、
  `make boot-qspi` 和 `make program` 在两种拨码位置下都能用。
- 烧写工具偶尔在启动阶段报 `Flash programming initialization failed`（实测约十次里一次），
  此时还没有擦写任何内容，脚本会自动重试，最多三次。

## 经 JTAG 临时加载

~~~bash
source /tools/Xilinx/Vitis/2024.2/settings64.sh
JTAG_CABLE_SERIAL=<序列号> make program
~~~

主机连接了多根 JTAG 线时必须用 `JTAG_CABLE_SERIAL` 指定板卡那根，否则脚本无法
唯一选中目标。`make program` 不会重新综合，也不会创建 Vitis 工程；它直接下载 XSA 和
ELF，掉电即失，不改动 flash。拨码在 QSPI32 时它同样可用：脚本先把这一次复位的启动模式
切到 JTAG，免得 flash 里的镜像同时启动。加载后板卡网络回到临时地址，需按
[软件使用说明](../docs/软件版本说明.md)重新发现和配置 IP。
