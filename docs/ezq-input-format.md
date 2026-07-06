# ez-Q 输入数据接口格式

本文定义 ez-Q 波形输入数据的结构、字段宽度、字段含义和取值范围。
目标是作为软件生成、10G 上传和硬件适配时的接口文档。

## 1. 总体结构

最终交付给上传程序的内容通常是一个目录，里面包含一份元数据和若干通道文件：

```text
artifact_dir/
  ezq_metadata.json
  ch1_ezq_wave_iq.npy
  ch1_ezq_wave_packed.npy
  ch1_ezq_seq.npy
  ch1_ezq_wave_hex.txt
  ch2_ezq_wave_iq.npy
  ...
```

数据关系如下：

| 层级 | 内容 |
| --- | --- |
| 目录级 | 一个完整的 ez-Q 波形包 |
| 元数据级 | `ezq_metadata.json` |
| 通道级 | `chN_ezq_wave_*.npy`、`chN_ezq_seq.npy`、`chN_ezq_wave_hex.txt` |

最小逻辑结构可以写成：

```text
ezq_package
  metadata
  channels[1..8]
    wave
    seq
```

单通道实例：

```text
ch1_ezq_wave_iq.npy    -> 2 x N 的 int16 数组
ch1_ezq_wave_packed.npy -> N 的 int32 数组
ch1_ezq_seq.npy        -> M x 4 的 uint16 数组
```

## 2. 最终到板卡的数据格式

最终真正从上位机发到板卡的不是 `chN_ezq_wave_iq.npy`，也不是 ez-Q 原始 `wave_seq`。
当前工程会先把 ez-Q 波形转换成当前板卡协议，然后通过 UDP 发送两类数据：

```text
1. DDR 写包：把波形数据写入板卡 DDR
2. 播放指令包：告诉硬件每个通道从 DDR 哪个地址读、读多长、使用哪种 DDR layout、是否启动
```

### 2.1 UDP DDR 写包

每个 UDP DDR 写包固定写入 32 字节波形数据。

包体格式如下：

```text
uint64 magic
uint64 ddr_addr
uint64 data0
uint64 data1
uint64 data2
uint64 data3
```

总长度：

```text
6 x uint64 = 48 bytes
```

字段定义：

| 字段 | 类型 | 字节数 | 字节序 | 含义 |
| --- | --- | --- | --- | --- |
| `magic` | `uint64` | 8 | little-endian | 固定值 `0x5741564544445230`，ASCII 为 `WAVEDDR0` |
| `ddr_addr` | `uint64` | 8 | little-endian | 本包 32B 数据写入 DDR 的物理地址 |
| `data0` | `uint64` | 8 | little-endian | 波形数据 byte `[0:7]` |
| `data1` | `uint64` | 8 | little-endian | 波形数据 byte `[8:15]` |
| `data2` | `uint64` | 8 | little-endian | 波形数据 byte `[16:23]` |
| `data3` | `uint64` | 8 | little-endian | 波形数据 byte `[24:31]` |

约束：

| 项 | 要求 | 硬件行为 |
| --- | --- | --- |
| `ddr_addr` | 必须 32B 对齐，即 `ddr_addr[4:0] == 0` | 不对齐时丢弃该写包，`udp_wave_align_error_count` 加 1 |
| payload | 固定 32B | 每包写一个 256-bit AXI beat |
| 短波形尾部 | 软件补零到 32B | 硬件不接收 byte strobe partial beat |

32 字节 `data0..data3` 内部就是一个 RFDC 256-bit beat：

```text
int16 lane0  = I0
int16 lane1  = Q0
int16 lane2  = I1
int16 lane3  = Q1
...
int16 lane14 = I7
int16 lane15 = Q7
```

也就是：

```text
I0,Q0,I1,Q1,I2,Q2,I3,Q3,I4,Q4,I5,Q5,I6,Q6,I7,Q7
```

每个 lane：

| 字段 | 类型 | 字节数 | 字节序 |
| --- | --- | --- | --- |
| `I[n]` / `Q[n]` | `int16` | 2 | little-endian |

### 2.2 DDR 中的 interleaved_512b 地址布局

当前默认 DDR layout 是 `interleaved_512b`。

常量：

| 名称 | 值 | 含义 |
| --- | --- | --- |
| `TILE_BYTES` | `4096` | 每通道每个 tile 的字节数 |
| `CHANNELS` | `8` | 固定预留 8 个通道 |
| `SUPERBLOCK_BYTES` | `32768` | `8 x 4096` |
| `BEAT_BYTES` | `32` | 每个 UDP 写包 / RFDC beat 字节数 |

地址公式：

```text
ddr_addr = base
         + tile_index * 32768
         + channel_index * 4096
         + intra_tile_offset
```

其中：

| 字段 | 含义 |
| --- | --- |
| `channel_index` | `channel - 1`，范围 `0..7` |
| `tile_index` | `channel_local_byte_offset / 4096` |
| `intra_tile_offset` | `channel_local_byte_offset % 4096` |

第一个 superblock：

```text
0x0000 - 0x0FFF : CH1 tile0
0x1000 - 0x1FFF : CH2 tile0
0x2000 - 0x2FFF : CH3 tile0
0x3000 - 0x3FFF : CH4 tile0
0x4000 - 0x4FFF : CH5 tile0
0x5000 - 0x5FFF : CH6 tile0
0x6000 - 0x6FFF : CH7 tile0
0x7000 - 0x7FFF : CH8 tile0
```

第二个 superblock：

```text
0x8000 - 0x8FFF : CH1 tile1
0x9000 - 0x9FFF : CH2 tile1
...
```

### 2.3 播放指令包

波形写入 DDR 后，上位机再发送播放指令。
每条播放指令固定 16 字节：

```text
uint32 word0
uint32 word1
uint32 word2
uint32 word3
```

字段定义：

| 字段 | 类型 | 字节数 | 字节序 | 含义 |
| --- | --- | --- | --- | --- |
| `word0` | `uint32` | 4 | little-endian | opcode、channel、flags |
| `word1` | `uint32` | 4 | little-endian | delay cycles 或 length bytes |
| `word2` | `uint32` | 4 | little-endian | DDR 地址低 32 位 |
| `word3` | `uint32` | 4 | little-endian | DDR 地址高 32 位 |

`word0` 位域：

```text
bits [3:0]   opcode
bits [7:4]   channel
bits [9:8]   flags
bits [31:10] reserved
```

`opcode`：

| 值 | 名称 | 含义 |
| --- | --- | --- |
| `1` | `BEGIN/IDLE` | 设置通道 delay / arm |
| `2` | `PLAY` | 从 DDR 读取波形并输出 |
| `3` | `END` | 结束配置；可 auto-start |

`channel`：

| 值 | 含义 |
| --- | --- |
| `1..8` | CH1..CH8 |
| `15` | END 指令中表示 auto-start |
| `0` | END 指令中表示等待触发 |

`flags`：

| bit | 值 | 含义 |
| --- | --- | --- |
| bit 0 | `0x1` | loop enable |
| bit 1 | `0x2` | interleaved_512b / legacy tiled DDR layout |

PLAY 指令约束：

| 项 | 要求 | 硬件行为 |
| --- | --- | --- |
| `word1` length bytes | 必须 32B 对齐 | 不对齐时拒绝该 PLAY，`ex_dbg_bad_instr_count` 加 1 |
| `word2/word3` DDR addr | 必须 32B 对齐 | 不对齐时拒绝该 PLAY，`ex_dbg_bad_instr_count` 加 1 |
| interleaved partial beat | 允许最后一个 beat 小于完整记录 | 但 BTT 仍必须是 32B 的整数倍 |

### 2.4 当前一次 8 通道播放的典型指令序列

每个通道两条指令：

```text
BEGIN channel N
PLAY  channel N
```

最后一条 END：

```text
END channel 15   # auto-start
```

对于 interleaved_512b layout，CH1 的 PLAY 指令等价于：

```text
opcode  = 2
channel = 1
flags   = 0x2
length  = channel_wave_bytes
addr    = 0x0000000000000000
```

CH2：

```text
opcode  = 2
channel = 2
flags   = 0x2
length  = channel_wave_bytes
addr    = 0x0000000000001000
```

CH1 的后续读取地址由硬件 interleaved 播放逻辑递增到：

```text
0x0000000000008000
```

## 3. 数据对象

ez-Q 下发输入由两类数据组成：

| 对象 | 必选 | 单位 | 说明 |
| --- | --- | --- | --- |
| `wave_data` | 是 | sample | 波形存储区数据 |
| `wave_seq` | 是 | 4 x uint16 | 波形播放控制序列 |

`wave_data` 定义输出样点，`wave_seq` 定义播放地址、长度、延时、触发、循环和停止。

## 4. 波形数据格式

### 2.1 单路实数波形

适用于 `RI`、`Z` 或非 IQ 输出。

| 字段 | 类型 | 字节数 | 含义 |
| --- | --- | --- | --- |
| `sample[n]` | `int16` / `uint16` | 2 | 第 n 个输出采样点 |

内存布局：

```text
sample0, sample1, sample2, ...
```

### 2.2 IQ 矩阵波形

适用于 `XY`、`RO`。

| 字段 | 类型 | 字节数 | 含义 |
| --- | --- | --- | --- |
| `I[n]` | `int16` | 2 | 第 n 个 I 样点 |
| `Q[n]` | `int16` | 2 | 第 n 个 Q 样点 |

数组结构：

```text
wave_data[0][n] = I[n]
wave_data[1][n] = Q[n]
```

约束：

| 约束 | 要求 |
| --- | --- |
| 维度 | `2 x N` |
| I/Q 长度 | 必须相等 |
| 推荐字节序 | little-endian |

### 2.3 打包 IQ 波形

适用于文件保存或紧凑传输。

单个复数样点占 4 字节：

```text
packed[n] = (Q[n] << 16) | (I[n] & 0xFFFF)
```

位域：

| 位段 | 字节数 | 含义 |
| --- | --- | --- |
| `[15:0]` | 2 | I 样点 |
| `[31:16]` | 2 | Q 样点 |

内存布局按 little-endian `int32` 保存时：

```text
I0_L, I0_H, Q0_L, Q0_H, I1_L, I1_H, Q1_L, Q1_H, ...
```

### 2.4 当前 RFSoC 工程规范化格式

当前工程内部统一使用 interleaved int16：

| 字段 | 类型 | 字节数 | 含义 |
| --- | --- | --- | --- |
| `lane[2n]` | `int16` | 2 | `I[n]` |
| `lane[2n+1]` | `int16` | 2 | `Q[n]` |

内存布局：

```text
I0, Q0, I1, Q1, I2, Q2, ...
```

每个复数样点占 4 字节。

## 5. 控制序列格式

### 3.1 序列行结构

每条 `wave_seq` 指令固定 8 字节，由 4 个 little-endian `uint16` 组成：

```text
word0: start_addr
word1: length
word2: count
word3: ctrl
```

| 字段 | 类型 | 字节数 | 含义 |
| --- | --- | --- | --- |
| `start_addr` | `uint16` | 2 | 波形起始地址，单位由通道类型决定 |
| `length` | `uint16` | 2 | 输出长度，单位由通道类型决定 |
| `count` | `uint16` | 2 | 延时计数、循环次数或跳转地址 |
| `ctrl` | `uint16` | 2 | 控制字 |

扁平数组格式：

```text
start0, length0, count0, ctrl0,
start1, length1, count1, ctrl1,
...
```

二维数组格式：

```text
[
  [start_addr, length, count, ctrl],
  ...
]
```

### 3.2 `ctrl` 控制字位域

| 位段 | 宽度 | 名称 | 含义 |
| --- | --- | --- | --- |
| `[7:0]` | 8 bit | `delay_low` | 触发/延时低位参数 |
| `[9:8]` | 2 bit | `level` | 循环层级 |
| `[10]` | 1 bit | `mark` | 输出触发标记 |
| `[14:11]` | 4 bit | `func` | 功能码 |
| `[15]` | 1 bit | `stop` | 停止标记 |

解码公式：

```text
func  = (ctrl >> 11) & 0xF
level = (ctrl >> 8)  & 0x3
mark  = (ctrl >> 10) & 0x1
stop  = (ctrl >> 15) & 0x1
```

### 3.3 `func` 功能码

| `func` | `ctrl` 基值 | 名称 | `count` 含义 |
| --- | --- | --- | --- |
| `0` | `0x0000` | `DI` 直接输出 | 通常为 0 |
| `1` | `0x0800` | `LS` 循环开始 | 循环次数 |
| `2` | `0x1000` | `LE` 循环结束 | 跳转序列地址 |
| `4` | `0x2000` | `DL` 延时 | 延时计数 |
| `8` | `0x4000` | `TR` 触发输出 | 通常为 0 |
| `12` | `0x6000` | `CD` 态判断输出 | 判断/跳转参数 |

停止指令通过 `stop=1` 表示，常见控制字为：

```text
ctrl = 0x8000
```

### 3.4 常见指令编码

#### 直接输出

| 字段 | 值 |
| --- | --- |
| `start_addr` | 波形起始地址 |
| `length` | 波形长度 |
| `count` | `0` |
| `ctrl` | `0x0000` |

#### 延时

| 字段 | 值 |
| --- | --- |
| `start_addr` | idle 波形地址 |
| `length` | idle 波形长度 |
| `count` | delay count |
| `ctrl` | `0x2000` |

#### 循环开始

| 字段 | 值 |
| --- | --- |
| `start_addr` | idle 波形地址 |
| `length` | idle 波形长度 |
| `count` | loop count |
| `ctrl` | `0x0800 | (level << 8)` |

#### 循环结束

| 字段 | 值 |
| --- | --- |
| `start_addr` | idle 波形地址 |
| `length` | idle 波形长度 |
| `count` | loop start sequence index |
| `ctrl` | `0x1000 | (level << 8)` |

#### 停止

| 字段 | 值 |
| --- | --- |
| `start_addr` | idle 波形地址，通常 0 |
| `length` | idle 波形长度 |
| `count` | 通常 0 |
| `ctrl` | `0x8000` |

## 6. 通道类型参数

| 通道类型 | 数据形态 | `samples_per_clk` | `clock_period` | 地址/长度单位 |
| --- | --- | --- | --- | --- |
| `RI` | real | 1 | 3.2 ns | 1 sample |
| `XY` | IQ | 2 或 4 | 4 ns / 8 ns | `samples_per_clk` 折算后单位 |
| `RO` | IQ | 8 | 4 ns | `samples_per_clk` 折算后单位 |
| `Z` | real | 4 | 4 ns | `samples_per_clk` 折算后单位 |

说明：

- 具体取值由调用脚本中的 `classes` / `ch_type` 决定。
- 序列中的 `start_addr` 和 `length` 通常已经右移 `log2(samples_per_clk)`。

## 7. 文件级接口

### 5.1 推荐文件集合

| 文件 | 格式 | 必选 | 说明 |
| --- | --- | --- | --- |
| `chN_wave_iq.npy` | `int16[2, N]` | IQ 通道必选 | I/Q 矩阵 |
| `chN_wave_packed.npy` | `int32[N]` | 可选 | `Q << 16 | I` 打包格式 |
| `chN_seq.npy` | `uint16[M, 4]` | 必选 | 播放控制序列 |
| `metadata.json` | JSON | 推荐 | 通道、采样率、布局等元数据 |

### 5.2 `metadata.json` 建议字段

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `layout` | string | DDR 布局，例如 `interleaved_512b` / `tiled` / `contiguous` |
| `channels` | array | 通道描述列表 |
| `channel` | int | 通道号 |
| `wave_iq_npy` | string | IQ 矩阵文件 |
| `wave_packed_npy` | string | packed IQ 文件 |
| `seq_npy` | string | 序列文件 |
| `complex_samples` | int | 复数样点数 |
| `bytes_per_channel` | int | 单通道波形字节数 |

## 8. `waves/*.json` 样例文件

样例 JSON 顶层结构：

```json
{
  "config": {},
  "waves": [],
  "data": {}
}
```

| 字段 | 类型 | 用途 | 是否用于下发 |
| --- | --- | --- | --- |
| `config` | object | 实验和波形参数 | 可作为 metadata |
| `waves` | array | 通道波形数组 | 是 |
| `data` | object | 测量/解调结果 | 否 |

注意：`data` 不是下发波形，不能作为 DAC 输入。

## 9. 当前项目接收规范

当前 RFSoC 工程推荐接收以下规范化格式：

| 项 | 要求 |
| --- | --- |
| 波形 | interleaved int16 |
| IQ 顺序 | `I0,Q0,I1,Q1,...` |
| 每复数样点 | 4 bytes |
| 每 RFDC beat | 32 bytes |
| 每 beat 复数样点数 | 8 |
| 序列 | `uint16[M,4]` |
| 默认 DDR layout | `interleaved_512b` |

当前工程中每个 256-bit RFDC AXIS beat 的 lane 排列：

```text
lane0  = I0
lane1  = Q0
lane2  = I1
lane3  = Q1
...
lane14 = I7
lane15 = Q7
```
