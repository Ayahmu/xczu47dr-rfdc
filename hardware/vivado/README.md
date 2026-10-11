# Vivado 硬件构建

`src/` 放 RTL（其中 `udp/` 是 64 位 UDP/IP 协议栈，`udp100g/` 是 100G CMAC 封装和批量
上传接收通路），`bd/` 放 Block Design，`xdc/` 和 `constraints/` 放引脚、时序和 TDC 布局约束，
`scripts/` 放自动化流程。`src/` 下的每个文件都会进入工程，不再
使用的模块应直接删除。工程和报告只在本地生成。

## 关键接口

- RFDC：6.4 GS/s、16 倍插值、400 MS/s IQ、50 MHz AXIS。
- DDR4：8 GiB，300 MHz 用户时钟，512-bit AXI。
- 网络：100G CMAC（CAUI-4、RS-FEC）。控制命令走 64 位协议栈；批量波形数据在 CMAC
  输出处分流，以 512-bit 位宽直接写 DDR4。
- XS17 外部参考（250 或 10 MHz）经 HMC7044 产生 10 MHz PLL1 PFD 和 128 MHz DAC 参考。
- XS18（TRIG_1）在每次播放的第一个样点输出标记脉冲，XS19（TRIG_2）为外部 Trigger 输入。
- PS 只经 `M_AXI_GPIO` 写固件状态字（`firmware_status_reg.v`）、经 `M_AXI_RFDC` 访问 RFDC，
  并可经 `M_AXI_PS_DDR` 读写 PL DDR4。

## 分步命令

~~~bash
source /tools/Xilinx/Vivado/2024.2/settings64.sh

make vivado-project     # 生成工程和 IP
make preflight          # 只做 RTL 展开和结构检查
make synth
make xdc-check          # 核对 XDC 中带 -quiet 的对象查询仍能匹配综合网表
make impl
make bitstream
make xsa
~~~

构建选项通过环境变量传入：`TIMING_GATE=0` 关闭时序门限（仅限诊断构建），`IMPL_MODE`
选择实现策略（默认先平衡、不过再激进）。
