# Chisel 硬件生成器

Chisel 源码用于生成可综合 Verilog 以及 RFDC、DDR4 的 Vivado 配置 Tcl。Vivado 顶层和 UDP
协议代码不在这里维护，统一位于 `hardware/vivado/`。

## 环境

- Mill 0.11.6
- Java 8 或更高版本
- Scala 由 Mill 自动管理

## 常用命令

~~~bash
./build.sh all       # 生成全部模块和配置
./build.sh reset     # 只生成复位同步模块
./build.sh rfdc      # 只生成 RFDC 配置 Tcl 和封装
./build.sh ddr       # 只生成 DDR4 配置 Tcl 和封装
./build.sh clean
~~~

生成物位于 `generated/`，Mill 的 `out/` 是缓存目录，都不要手工修改。

## 模块目录

`reset/` 生成各时钟域的复位同步模块 `ChiselProcSysReset`；`rfdc/` 和 `ddr/` 生成定制
XCZU47DR 的 RFDC、DDR4 IP 参数 Tcl 及其 Verilog 封装。
