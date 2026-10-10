# 可烧写文件

本目录对应 XS17=250 MHz 参考、100G QSFP28 网口的单板波形产品。`artifacts/` 是
`make program` 的唯一输入目录；这里的文件是构建后的交付物，不是源码。修改硬件或固件后
应由构建命令重新生成，并和对应源码一起提交。

## 文件

~~~text
custom_xczu47dr_waveform.xsa   硬件平台（内含 *.tmp.bit、psu_init.tcl、build_manifest.json）
custom_xczu47dr_waveform.elf   PS 固件
SHA256SUMS                     上述文件的校验和
~~~

bitstream 只以 XSA 内嵌形式交付，烧写脚本会自动提取。`build_manifest.json` 记录构建
所用的源码提交（`source_commit`）以及构建时工作区是否有未提交改动（`source_dirty`）；
板卡 STATUS 返回的 `source_commit_id` 与其中的 `source_commit` 一致。

校验现有文件：

~~~bash
(cd artifacts && sha256sum -c SHA256SUMS)
~~~

## 烧写

~~~bash
source /tools/Xilinx/Vitis/2024.2/settings64.sh
JTAG_CABLE_SERIAL=<序列号> make program
~~~

主机连接了多根 JTAG 线时必须用 `JTAG_CABLE_SERIAL` 指定板卡那根，否则脚本无法
唯一选中目标。`make program` 不会重新综合，也不会创建 Vitis 工程；它直接下载 XSA 和
ELF。烧写后板卡网络回到临时地址，需按[软件版本说明](../docs/软件版本说明.md)重新发现
和配置 IP。
