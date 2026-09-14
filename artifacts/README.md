# 可烧写文件

本分支对应 XS17=250 MHz。仓库只保留生产主卡和从卡工件；debug、trigout、bandwidth、TDC 和带 `_rfdc` 后缀的临时工件不纳入交付。

`artifacts/` 是 `make program` 的唯一输入目录。这里的文件是构建后的交付物，
不是源码；修改硬件或固件后应由构建命令重新生成，并和对应源码一起提交。

## 主从文件

每个角色必须成套使用：

~~~text
custom_xczu47dr_master.xsa  .elf
custom_xczu47dr_slave.xsa   .elf
~~~

XSA 是 ZIP 兼容的硬件平台归档，内部包含 `*.tmp.bit` 和 `psu_init.tcl`；烧写脚本会自动提取它们。

主卡 XS20 输出，从卡 XS20 输入。不要把两个角色的文件混用。校验现有文件：

~~~bash
(cd artifacts && sha256sum -c SHA256SUMS)
~~~

## 烧写

~~~bash
source /tools/Xilinx/Vitis/2024.2/settings64.sh
JTAG_CABLE_SERIAL=<序列号> TARGET=custom_xczu47dr_slave make program
~~~

`make program` 不会重新综合，也不会创建 Vitis 工程；它直接下载对应角色的
XSA 和 ELF。烧写后板卡网络回到临时地址，需按[软件版本说明](../docs/软件版本说明.md)
重新发现和配置 IP。
