# 8 通道独立 NCO 单频波设计（IQ→Real / C2R，Zone2）

日期：2026-06-22
分支：feature/rfdc-8ch-nco-iq

## 目标

把用户层从 4 通道（per-tile）扩展为 8 通道（per-DAC），让 8 个物理 DAC 口
（vout00/02/10/12/20/22/30/32）各自打出**独立幅度、独立频率**的单频 CW。

- 频率方式：保留 fine-NCO 数字上变频，C2R（IQ→Real）。
- Nyquist Zone：**Zone2**（Fs=6.0 GSPS，Zone2 = 3.0~6.0 GHz）。
- 覆盖频段：3.5~5.5 GHz（整段干净落在 Zone2，无需切 Zone）。
- 5.5 GHz 进不了 Zone1（需 Fs≥11G，器件带 DUC 上限 9.85G），故 Zone2 是唯一可整段覆盖的方案。

## 关键器件事实（来自数据手册 ZU4xDR RF-DAC 电气特性表）

| Datapath Mode | 说明 | 最大 Fs（-2 速度等级） |
|---|---|---|
| 1 = Full Bandwidth（无 NCO） | Bypass | 7.0 GS/s |
| 2/3/4 = 带 DUC（有 fine NCO） | DUC | 9.85 GS/s（无 clock forwarding） |

结论：保留 NCO（mode 2，DUC 0-to-Fs/2）不掉速，反而是高速档。当前 Fs=6.0 远低于上限，
本次改动**不改采样率、不改时钟链、不改 RFDC IP 配置**。

## Zone2 频率换算

C2R fine mixer，基带在 DC，NCO 把它搬到 |f_nco|，Zone2 镜像：

    RF = Fs - |f_nco|  =>  f_nco = Fs - RF = 6.0 - RF (GHz)

| RF (GHz) | f_nco (GHz) |
|---|---|
| 3.5 | 2.5 |
| 4.5 | 1.5 |
| 5.5 | 0.5 |

f_nco ∈ [0.5, 2.5] < Fs/2=3.0，全部合法。

## 数据组织（不改 RTL）

已验证 RTL：axis_128_to_256 gearbox 把两个连续 128-bit DDR beat 拼成一个 256-bit tile 字：
- beat0（偶）→ 低 128 位 → slice0（vout_0）
- beat1（奇）→ 高 128 位 → slice2（vout_2）

因此 8 口独立**只需 host 在每个 tile 缓冲里按 beat 交替填两个 DAC 的常数**，RTL 不动。

| 用户通道 | DAC 口 | Tile | tile 缓冲内位置 |
|---|---|---|---|
| CH1 | vout00 | 0 | 偶 beat |
| CH2 | vout02 | 0 | 奇 beat |
| CH3 | vout10 | 1 | 偶 beat |
| CH4 | vout12 | 1 | 奇 beat |
| CH5 | vout20 | 2 | 偶 beat |
| CH6 | vout22 | 2 | 奇 beat |
| CH7 | vout30 | 3 | 偶 beat |
| CH8 | vout32 | 3 | 奇 beat |

executor 指令仍按 4 个 tile 下发（AXIS 是 4 个）；每个 tile 缓冲含其两个 DAC 各自的常数。

## firmware 改动

- 新增按口独立 NCO 配置：8 元素 RF 频率数组（编译期默认值），上电生效。
- 默认值：8 口全部 4.5 GHz（等效原行为，但可独立改）。
- 内部按 f_nco = 6.0 - RF 换算，逐口 GetMixerSettings → set Freq → SetMixerSettings → UpdateEvent。
- 改频率只需改数组重 build firmware，无需重综合 bitstream。

## host 改动

- 用户层从 4 通道扩为 8 通道（CH1-CH8）。
- 每口独立幅度。
- 每个 tile 缓冲按 beat 交替填该 tile 两个 DAC 的常数。
- 保持 DC 常数复基带（对 lane 交织不敏感）。

## 不改动项

- RFDC IP 配置 TCL（DAC_Mixer_Mode=1, Type=2 Fine, Data_Type=1 I/Q, Interp=8, Fs=6.0, Zone=2）
- 时钟链 / HMC7044 / PLL / fabric 时钟
- RTL（Top.v / gearbox / TopCustomXczu47dr.v）

## 验证

- 综合 / 实现 / bitstream / XSA：确认 0 error、时序 met。
- build firmware：确认 ELF 生成。
- host --dry-run：确认 8 口数据组织正确。
