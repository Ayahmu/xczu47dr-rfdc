# 确定性同步 路径1：CLKIN0 参考 + SYNC retime 可执行清单

## 目标

解决「同一轮发波延迟固定、不同上电/重新烧写之间延迟不固定」的问题，让主卡/从卡的
RF 输出相位差在**跨上电、跨重新烧写**时保持固定。

核心思路：把 10 MHz 参考（XS17）改接到 HMC7044 的 CLKIN0/RFSYNCIN（Reference 0），
同步脉冲仍走 SYNC 脚（pin 146），并打开 HMC7044 的 `SYNC retime from Reference 0`
（0x005B bit2）。这样 SYNC 边沿被参考时钟对齐，两片芯片在同一个确定相位点做
SYSREF/输出分频器 reseed，消除异步采样带来的量化模糊。

> 重要：本方案要求**硬件走线改动**（XS17 从 CLKIN1 改到 CLKIN0）。在改线完成之前，
> 下面的寄存器/软件改动不会生效，也不要烧到现有板卡上。

---

## 1. 原理图走线改动（硬件，前置）

现状（`定制卡1原理图.pdf` HMC7044 页）：

```text
XS17 (10MHz 参考)  ──>  HMC7044_CLKIN+/-  ──>  CLKIN1/FIN   (pin 36/37)
X3   (SSMC 外部同步) ──> NB6N11(1:2) ──Q1──>  EXT_SYNC      ──>  CLKIN0/RFSYNCIN (pin 39/40)
X3   (SSMC 外部同步) ──> NB6N11(1:2) ──Q0──>  EXT_TRIGGER   ──>  FPGA
FPGA H7044_SYNC ──> SYNC (pin 146)
```

目标走线：

```text
XS17 (10MHz 参考)  ──>  CLKIN0/RFSYNCIN (pin 39/40)   ← 唯一必须改的走线
X3   (SSMC 外部同步) ──> NB6N11(1:2) ──Q0──>  EXT_TRIGGER ──> FPGA   （不再直连 CLKIN0）
FPGA H7044_SYNC ──> SYNC (pin 146)                       （不变）
```

要动的点：

1. 断开 X3/NB6N11 Q1 → CLKIN0/RFSYNCIN 这条线。
2. 把 XS17 参考接到 CLKIN0/RFSYNCIN（保持差分、电平/端接与原来 CLKIN1 一致）。
3. CLKIN1 可悬空或保持不使能（软件侧已禁用）。
4. X3 仍进 FPGA（EXT_TRIGGER），以后接外部同步脉冲时由 FPGA 转发到 H7044_SYNC。

电气注意：

- CLKIN0 输入 buffer 模式（0x000A）保持与原来 CLKIN1（0x000B=0x07）一致的
  100Ω 端接 + AC 耦合 + LVPECL/LVDS 配置；若 XS17 电平标准不同，需一并调整。
- 差分极性按新走线确认（0x005B bit0 的 SYNC 极性暂保持 0=positive）。

---

## 2. hmc7044.vhd 寄存器改动

文件：`hardware/vivado/src/hmc7044.vhd`（`USE_EXTERNAL_XS17 = '1'` 分支）。

### 2.1 0x0005 Global mode and enable：0x5A → 0x41

```text
当前 0x5A = 0b01011010：
  [7:6]=01 SYNC through PLL2
  [5]  =0  CLKIN1 非外部 VCO
  [4]  =1  CLKIN0 作为 RF SYNC 输入      ← 关闭
  [3:0]=1010 使能 CLKIN1 + CLKIN3        ← 改为只使能 CLKIN0

目标 0x41 = 0b01000001：
  [7:6]=01 SYNC through PLL2（不变）
  [5]  =0 （不变）
  [4]  =0 CLKIN0 不再作为 RF SYNC（作为 PLL1 参考）
  [3:0]=0001 只使能 CLKIN0
```

改动：

```vhdl
if USE_EXTERNAL_XS17 = '1' then
    config_reg <= x"0005" & x"41"; -- CLKIN0 = XS17 reference, no RF SYNC
else
    config_reg <= x"0005" & x"56";
end if;
```

### 2.2 0x005B SYNC control：0x02 → 0x06

```text
当前 0x02 = 0b00000010：bit2=0（retime bypass）
目标 0x06 = 0b00000110：bit2=1（retime from Reference 0/CLKIN0）
                        bit1=1（through PLL2，不变）
                        bit0=0（positive，按新极性确认）
```

改动：

```vhdl
config_reg <= x"005B" & x"06"; -- SYNC retime from Reference 0 (CLKIN0)
```

### 2.3 0x0014 PLL1 Reference Priority：0x36 → 0x00（可选，单参考时优先级不影响）

```text
当前 0x36 第一优先级是 CLKIN2。
目标：第一优先级 = CLKIN0（编码 00）。单参考时可直接写 0x00。
```

改动：

```vhdl
config_reg <= x"0014" & x"00"; -- first priority = CLKIN0
```

### 2.4 需确认项

- `0x0003` bit5（RF reseeder enable）当前 = 1。路径1 不再用 RF SYNC，理论上可清 0
  （0x2F → 0x0F），但需上板确认是否影响 SYNC 脚的 reseed；保守做法先保持 0x2F。
- `0x000A`（CLKIN0 输入 buffer）保持 0x07；若 XS17 电平不同需改。
- `0x001C`（CLKIN0 prescaler）保持 0x01。
- R1（0x0021/0x0022）=1、N1（0x0026/0x0027）=10 不变（10MHz → 100MHz VCXO）。

---

## 3. XDC / FPGA 同步路径改动

同步脉冲链路不变：主卡 FPGA 发 SYNC → XS20 → 从卡 FPGA → 从卡 H7044_SYNC 脚。
所以 RTL / XDC 基本不用改：

- `sync_role_control.v` / `sync_trigger_link.v` / `Top.v`：保持现状（SYNC 直接驱动
  `H7044_SYNC`，不带 FPGA 侧重定时）。
- `custom_xczu47dr_minimal.xdc`：`H7044_SYNC`（pin E9）、`TRIG_3`(XS20)、
  `TRIG_2`(XS19)、`TRIG_1`(XS18) 约束不变。
- `EXT_TRIGGER_P/N`（X3）仍作为 FPGA 输入保留，供以后外部脉冲转发使用。
- 之前已删除的 `mclk_10m`（10MHz monitor 重定时）无需恢复——路径1 由 HMC7044 内部
  retime，不再需要 FPGA 侧重定时。

结论：**这部分无需改动**（除非要新增「X3 外部脉冲 → FPGA → H7044_SYNC」的转发逻辑，
那是后续接国盾时的独立任务）。

---

## 4. master / slave 各怎么配

master/slave 的角色由 bitstream 的 `IS_MASTER` 决定，HMC7044 寄存器两侧**完全相同**
（都用 CLKIN0 参考 + SYNC retime）。区别只在 XS20 电气方向：

- 主卡：XS20 为输出，FPGA 产生 SYNC 脉冲，打到本卡 `H7044_SYNC` 并经 XS20 送从卡。
- 从卡：XS20 为输入，FPGA 收到后转发到本卡 `H7044_SYNC`。

两侧 HMC7044 均：CLKIN0=XS17 参考、0x0005=0x41、0x005B=0x06（retime）、
0x0014=0x00。不需要任何 master/slave 差异化寄存器。

---

## 5. 验证方法

1. 静态检查：`python3 -m unittest tests.test_hmc7044_config`（更新断言
   `0x0005==0x41`、`0x005B==0x06` 后应通过）。
2. 上板：UART 确认 HMC7044 锁 PLL1/PLL2、SYSREF 有效。
3. ILA：抓 `H7044_SYNC`、SYSREF、DAC 相位，确认 SYNC 边沿相对参考对齐。
4. 重复上电/重新烧写 ≥10 次，每次用驱动发同一波形，示波器测主从 RF 相位差，
   确认跨上电固定（这是最终验收标准，不能用驱动状态代替示波器测量）。

---

## 执行顺序（重要）

1. 先改硬件走线（XS17 → CLKIN0）。
2. 改 `hmc7044.vhd` 寄存器 + 更新测试断言。
3. `make bitstream-dual` 生成主从 bitstream。
4. 烧写两卡，按第 5 节验收。

在硬件改线前，不要把 0x0005=0x41 / 0x005B=0x06 烧到现有接法（XS17 还在 CLKIN1）的
板卡上。
