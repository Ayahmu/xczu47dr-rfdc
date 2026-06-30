# 8 路 DAC 独立输出进度与下一步

日期：2026-06-29

## 当前结论

8 路独立 DAC 输出的软件链路和主要 RTL 源码已经完成扩展。当前状态不是“只写完代码”，而是已经通过了软件单元测试、RFDC Chisel 生成、RTL 源码 grep 检查、Vivado 语法分析，以及 `dac_play_ctrl` 的 focused elaboration/simulation。尚未完成的是完整 Vivado 工程级综合/实现和上板 RF 实测。

## 已完成

### 1. 软件 8 通道链路

已把 host、CLI、GUI、波形生成、ILA report 默认路径扩展到 CH1-CH8。

关键文件：

- `software/host.py`
- `software/waveform_tools.py`
- `software/send_waveform_udp.py`
- `software/waveform_gui_model.py`
- `software/waveform_gui.py`
- `software/ila_capture_report.py`
- `software/README.md`

DDR buffer offset 当前约定：

| Channel | DDR offset | RFDC AXIS | Physical output |
|---|---:|---|---|
| CH1 | `0x0000` | `s00_axis` | `vout00` |
| CH2 | `0x40000` | `s02_axis` | `vout02` |
| CH3 | `0x80000` | `s10_axis` | `vout10` |
| CH4 | `0xC0000` | `s12_axis` | `vout12` |
| CH5 | `0x100000` | `s20_axis` | `vout20` |
| CH6 | `0x140000` | `s22_axis` | `vout22` |
| CH7 | `0x180000` | `s30_axis` | `vout30` |
| CH8 | `0x1C0000` | `s32_axis` | `vout32` |

软件测试已通过：

```bash
cd /home/kyu/workspace/xczu47dr-rfdc
python3 -m unittest tests.test_host_udp_waveform tests.test_waveform_tools tests.test_send_waveform_udp tests.test_waveform_gui tests.test_waveform_gui_model tests.test_ila_capture_report
```

结果：

```text
Ran 82 tests in 0.670s
OK
```

### 2. RTL 8 通道扩展

主要修改集中在：

- `hardware/vivado/src/waveform_system_top.v`
- `hardware/vivado/src/dac_play_ctrl.v`
- `hardware/vivado/src/Top.v`

已完成的 RTL 方向：

- `waveform_system_top.v` 从 4 路 DataMover/FIFO 调度扩展到 CH1-CH8。
- `dm_sel` 已从 2 bit 调整为 3 bit，并修掉了残留的 `2'd0..2'd3` 比较/复位。
- `dac_play_ctrl.v` 从 4 路 playback gating 扩展到 CH1-CH8。
- `Top.v` 已把 FIFO、gearbox、play control 和 RFDC AXIS 端口接到 8 个物理输出。
- `tests/tb_dac_play_ctrl.sv` 已补齐 CH5-CH8 端口实例。
- `dac_play_ctrl.v` 已加入 `` `timescale 1ns/1ps``，使 Vivado `xelab` 不再因 testbench/module timescale 不一致失败。

源码 grep 检查未发现旧的可维护源码层 tie-off/镜像关键字：

```bash
grep -R "dac02_valid_in(1'b0)\|dac12_valid_in(1'b0)\|dac22_valid_in(1'b0)\|dac32_valid_in(1'b0)\|dac02_data_in(256'b0)\|dac12_data_in(256'b0)\|dac22_data_in(256'b0)\|dac32_data_in(256'b0)" -n hardware/vivado/src hardware/chisel --exclude-dir=generated
```

结果：无输出。

### 3. Vivado focused validation

`waveform_system_top.v` 和 `Top.v` 的语法分析通过：

```bash
cd /home/kyu/workspace/xczu47dr-rfdc
/tools/Xilinx/Vivado/2024.2/bin/xvlog -sv hardware/vivado/src/waveform_system_top.v hardware/vivado/src/Top.v
```

关键输出：

```text
analyzing module Waveform_System_Top
analyzing module Waveform_Instruction_Decoder
analyzing module Waveform_Channel_State
analyzing module Waveform_Dma_Selector
analyzing module Top
```

`dac_play_ctrl` testbench 的分析、elaboration 和仿真通过：

```bash
cd /home/kyu/workspace/xczu47dr-rfdc
/tools/Xilinx/Vivado/2024.2/bin/xvlog -sv hardware/vivado/src/dac_play_ctrl.v tests/tb_dac_play_ctrl.sv
/tools/Xilinx/Vivado/2024.2/bin/xelab tb_dac_play_ctrl -s tb_dac_play_ctrl_sim
/tools/Xilinx/Vivado/2024.2/bin/xsim tb_dac_play_ctrl_sim -runall
```

结果：

```text
PASS: dac_play_ctrl starts with auto_start after FIFO prog_empty deasserted
```

### 4. RFDC Chisel 生成

RFDC config/wrapper 已重新生成：

```bash
cd /home/kyu/workspace/xczu47dr-rfdc/hardware/chisel
./build.sh rfdc
```

结果：

```text
RFDC Vivado configuration generated: generated/rfdc_custom_xczu47dr_config.tcl
RFDC Verilog blackbox wrapper generated: generated/RfdcCustomXczu47dr.v
Build complete
```

已确认生成配置仍包含 8 个 AXIS bus interface：

```text
s00_axis:s02_axis:s10_axis:s12_axis:s20_axis:s22_axis:s30_axis:s32_axis
```

## 仍未完成

### 1. 完整 Vivado 工程综合/实现

目前只跑过 focused `xvlog`、`xelab`、`xsim`，还没有跑完整 Vivado project 的 synthesis/implementation。因此还不能断言 bitstream 已经可生成，也不能断言时序收敛。

下一步优先跑：

```bash
cd /home/kyu/workspace/xczu47dr-rfdc
make synth
```

如果 `make synth` 通过，再继续：

```bash
make impl
make bitstream
```

如果 synthesis 失败，优先看：

- 端口名 mismatch。
- RFDC wrapper/IP 端口和 `Top.v` 端口是否一致。
- ILA probe 宽度是否仍匹配。
- `cfg_cdc_fifo_xpm` 宽度是否与 `Top.v` 中 544-bit config payload 一致。
- generated RFDC IP 是否仍把 `dac02/dac12/dac22/dac32` 这类路径 tie 到 0；如果出现，只修 generator/source，不手改 synth output。

### 2. 上板 RF 实测

完整 bitstream 生成后，需要上板验证物理输出真的独立。

建议步骤：

1. 只测 CH1/CH2。
   - CH1 输出低幅度 DC 或 CW 到 `vout00`。
   - CH2 输出不同幅度/频率/相位到 `vout02`。
   - 目标：`vout00` 和 `vout02` 同时有信号，且可独立变化。

2. 测 CH3/CH4。
   - 对应 `vout10` 和 `vout12`。

3. 测 CH5/CH6。
   - 对应 `vout20` 和 `vout22`。

4. 测 CH7/CH8。
   - 对应 `vout30` 和 `vout32`。

5. 最后 8 路同时输出。
   - 目标：无通道串接、无旧的 slice2 平坦输出问题、无明显通道互相镜像。

## 重要注意事项

- 不要手改 `hardware/vivado/ip/.../synth/...` 下的 generated synth 文件。那里只能作为现象证据。
- `waveform_executor.v` 不存在，executor/DataMover 逻辑在 `hardware/vivado/src/waveform_system_top.v`。
- 本环境没有 `rg`，继续用 `grep -R`。
- Python LSP 当前不可用，已用实际测试和 Vivado tools 作为验证依据。
- `iverilog`/`verilator` 不可用，RTL focused simulation 使用 Vivado `xvlog/xelab/xsim`。

## 如果继续开发，建议执行顺序

1. 跑 `make synth`。
2. 若失败，先修 source-level port/wire/width 问题，再重跑 focused `xvlog`。
3. synthesis 通过后跑 `make impl`。
4. implementation 通过后跑 `make bitstream`。
5. 生成 bitstream 后按“上板 RF 实测”逐对验证。
6. 每次 RTL 或 generator 改动后，重复以下 quick gates：

```bash
cd /home/kyu/workspace/xczu47dr-rfdc
/tools/Xilinx/Vivado/2024.2/bin/xvlog -sv hardware/vivado/src/waveform_system_top.v hardware/vivado/src/Top.v
/tools/Xilinx/Vivado/2024.2/bin/xvlog -sv hardware/vivado/src/dac_play_ctrl.v tests/tb_dac_play_ctrl.sv
/tools/Xilinx/Vivado/2024.2/bin/xelab tb_dac_play_ctrl -s tb_dac_play_ctrl_sim
/tools/Xilinx/Vivado/2024.2/bin/xsim tb_dac_play_ctrl_sim -runall
python3 -m unittest tests.test_host_udp_waveform tests.test_waveform_tools tests.test_send_waveform_udp tests.test_waveform_gui tests.test_waveform_gui_model tests.test_ila_capture_report
```

## 相关完整快照

更详细的历史和验证记录见：

- `docs/project-status-2026-06-29-8ch-dac.md`
