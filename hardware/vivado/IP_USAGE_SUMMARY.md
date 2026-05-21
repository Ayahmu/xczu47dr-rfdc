# 当前 FPGA 设计与最终 ASIC 目标差距摘要

## 总体状态

| 功能块 | 当前 FPGA 实现 | 最终 ASIC 目标 | 当前状态 | 还缺什么 |
|---|---|---|---|---|
| 控制面 | Zynq PS + AXI + `AXIGPIOBlackBox` + UDP 指令 | 纯 RTL 控制入口 | 部分完成 | 去掉 PS 依赖 |
| 波形输入 | `xxv_ethernet` + `udp_10G` + `udp_waveform_ddr_writer` | ASIC 输入接口 + parser | parser 部分完成 | 替换 MAC/PCS/GT |
| 波形存储 | Xilinx `ddr4_0` + AXI 写入/读取 | ASIC 存储接口 | 数据格式已明确 | 替换 DDR4 IP |
| DDR 读回播放 | Xilinx `axi_datamover_0` + `Waveform_System_Top` | 自研读 DMA + executor | executor 已有 | 替换 DataMover |
| AXI 互连 | Xilinx `smartconnect_2` | 自研仲裁/NoC | 未完成 | 实现存储仲裁 |
| FIFO/CDC | Xilinx `axis_data_fifo`、`axis_async_fifo_128`、`xpm_fifo_async` | 自研 FIFO/CDC | 接口已明确 | 替换 Xilinx FIFO |
| DAC 输出 | Xilinx `usp_rf_data_converter_0` + 自研 AXIS 适配/门控 | ASIC DAC 接口 | 播放逻辑部分完成 | 定义 DAC macro 边界 |
| 时钟/复位 | PS/BD 输出、`clk_wiz`、`proc_sys_reset`、HMC7044 控制 | ASIC 时钟/复位控制 | 板级控制可参考 | 替换 clk/reset IP |

## 当前必须依赖 Xilinx IP 的部分

这些是当前 RFSoC FPGA 板级验证无法用普通 RTL 等价替代的部分，必须继续通过 Xilinx IP 完成 bring-up。但它们不是 ASIC 最终交付物。

| 当前 IP | 使用位置 | 为什么当前必须用 | ASIC 处理方式 |
|---|---|---|---|
| `usp_rf_data_converter_0` | BD `design_1`，`Top.v` 连接 DAC `S_AXIS_20`/`S_AXIS_22` | RFSoC DAC Tile 是 Xilinx 硬核资源，配置、时钟和 AXIS 接口由 RFDC IP 管理 | 删除 RFDC IP；改为 ASIC DAC digital interface/analog macro wrapper |
| `ddr4_0` | BD `design_1` | 当前板上 DDR4 PHY、training、calibration 和 AXI 用户口由 Xilinx DDR4 controller 提供 | 删除 Xilinx DDR4 IP；接 ASIC SRAM/DDR controller/NoC，或重新定义片上存储结构 |
| `xxv_ethernet` | `udp_10G` 参考栈内部 | SFP+ 10G 的 MAC/PCS/GT 收发器是 FPGA 高速接口 IP | 删除 Xilinx Ethernet/GT；接 ASIC SerDes/Ethernet MAC，或改成最终芯片实际输入接口 |
| `zynq_ultra_ps_e_0` | BD `design_1` | 当前 bring-up 用 PS 提供 AXI master、时钟、复位、中断和软件控制 | 最终无 PS；控制面必须由纯 RTL 寄存器和外部接口承担 |

## 必须替换为自研 RTL 或 ASIC macro wrapper 的 Xilinx IP

这些 IP 主要是 Vivado 便利模块。它们不是物理硬核本身，ASIC 中应优先改成明确的 Verilog 实现或 foundry/library macro wrapper。

| 当前 IP/模块 | 当前功能 | ASIC 替换要求 | 优先级 |
|---|---|---|---|
| `axi_datamover_0` | 根据 `Waveform_System_Top` 命令从 DDR 读 128-bit AXIS 波形 | 写自研 read DMA：AXI/存储读请求、burst 拆分、返回数据排序、backpressure、状态/错误输出 | 高 |
| `smartconnect_0` / `smartconnect_2` | PS 控制互连、DDR 访问汇聚 | 删除 PS 互连；为 UDP writer 与 read DMA 实现专用仲裁或接入 ASIC NoC | 高 |
| `axis_data_fifo_1` / `axis_async_fifo_128` | 指令和波形数据缓冲 | 用参数化 Verilog FIFO 或 memory macro FIFO 替换 | 高 |
| `xpm_fifo_async` / `cfg_cdc_fifo_xpm` | DDR clock 到 DAC clock 配置 CDC | 用 ASIC 可综合异步 FIFO 或握手 CDC 替换，明确 reset 同步策略 | 高 |
| `proc_sys_reset` | 各时钟域 reset 生成 | 自研 reset synchronizer/reset controller，接 PLL lock 和外部 reset | 中 |
| `clk_wiz_dac_axis_0` | FPGA 内部生成 DAC AXIS clock | ASIC PLL/clock mux/clock divider wrapper，或由顶层时钟输入提供 | 中 |

## 已经相对接近 ASIC RTL 的部分

以下模块当前已经是 Verilog/VHDL RTL，原则上可以作为 ASIC 数字逻辑迁移的基础，但仍需要去掉 FPGA 专用 primitive、补齐 ASIC 约束和验证。

| 模块 | 当前功能 | ASIC 迁移状态 | 注意事项 |
|---|---|---|---|
| `udp_waveform_ddr_writer` | 解析 UDP payload，把波形数据写入 AXI DDR offset | 可迁移主体逻辑 | 需要把 AXI DDR 写口抽象成最终 memory write port；补充协议/异常场景验证 |
| `udp64_to_axis128_instr` | 64-bit UDP 指令拼成 128-bit AXIS 指令 | 可迁移 | 需要固定最终指令格式和端序 |
| `Waveform_System_Top` | 播放指令解析、DataMover command、双通道调度 | 可迁移主体逻辑 | 目前输出的是 DataMover command；需改成自研 read DMA command |
| `dac_play_ctrl` | trigger/delay/length 播放门控 | 可迁移 | 需要按最终 DAC clock/reset/trigger 同步方案重新验证 |
| `axis_128_to_64` / `axis_to_rfdc_continuous` | DAC 前数据宽度转换和连续输出 | 可迁移思路 | 最终数据宽度、ready/valid 语义要跟 ASIC DAC macro 对齐 |
| `hmc7044` | 板级时钟芯片 SPI 配置 | 只适用于当前板级 bring-up | ASIC 内部不应依赖板级 HMC7044；除非封装外仍需要控制外部时钟芯片 |