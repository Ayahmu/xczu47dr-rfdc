 # PL RISC-V 控制路径试验

 这里保留一个独立的 riscv-mini 生成入口，以及当前可综合的
 hardware/vivado/src/pl_riscv_control_v1.v 控制 shim。它不替代现有 RFCTRL2
 波形数据通路，波形仍通过 WAVEDDR0/WAVESTR0 写入 DDR。

 ## 生成上游代码

 ~~~bash
 hardware/riscv-mini/scripts/fetch_riscv_mini.sh
 hardware/riscv-mini/scripts/generate_tile_sv.sh
 ~~~

 上游源码放在被 Git 忽略的 vendor/，生成的 Tile.sv 放在被忽略的 generated/。
 当前 V1 尚未把生成 Tile 接入 Top.v，实际综合使用的是 PL shim。

 ## 控制协议

 RVCTRL0 和 RVCTRL1 是小控制包，支持 PING、MMIO、PLAY、TRIGGER 和 RFDC
 寄存器操作；响应为 RVRESP1。协议字段和 Python 发送命令见
 [API 参考](../../docs/API参考.md)，不要在这里复制维护完整协议表。
