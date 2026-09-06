# 方案 B 快速上手指南

## 你现在有什么

✅ **两个分支的 bitstream 已构建完成并推送**：
- 10 MHz 分支：`fix/dual-board-network-sync` (dc787b4)
- 250 MHz 分支：`xs17-250mhz-sync` (7a75e52)

✅ **方案 B 完全集成**：
- 200 MHz 相位检测器（8 个 phase slot）
- 0-7 个 fabric cycle 补偿器（每个 2.5 ns）
- 固件扩展：STATUS 响应包含 `phase_slot` 和 `phase_valid`
- 测试脚本：`hardware_slave_phase_compensation_test.py`

✅ **完整文档**：
- 技术详解、测试指南、故障排查

---

## 立即测试（3 步）

### 步骤 1：连接 JTAG 并加载 bitstream

```bash
# 检查 JTAG 连接
lsusb | grep Xilinx

# 如果没有输出，连接 JTAG 电缆到板卡和主机

# 加载 10 MHz slave bitstream（方案 B 已集成）
cd /home/kyu/workspace/xczu47dr-rfdc
make TARGET=custom_xczu47dr_slave program

# 或者手动指定路径
make program BIT=artifacts/custom_xczu47dr_slave.bit \
             ELF=artifacts/custom_xczu47dr_slave.elf \
             PSU_INIT=artifacts/custom_xczu47dr_slave_psu_init.tcl
```

**预期输出**：
```
Programming PL via JTAG...
Downloading ELF to PS...
✓ Programming complete
```

### 步骤 2：发现板卡 IP

```bash
# 板卡的 IP 会随 bitstream 变化（DNA 生成的 MAC 地址不同）
PYTHONPATH=software python3 - <<'PY'
from dr47.network import discover_boards
bs = discover_boards(interface="enp1s0f0", 
                     source_ip="169.254.250.11",
                     source_cidr="169.254.250.11/16",
                     broadcast_ip="169.254.255.255", 
                     port=1234)
if not bs:
    print("ERROR: No board found")
    exit(1)
for b in bs:
    print(f"FOUND: IP={b.current_ip} MAC={b.current_mac} UID={b.device_uid}")
PY
```

**预期输出**：
```
FOUND: IP=169.254.21.60 MAC=02:00:00:ad:15:91 UID=0x...
```

**记住这个 IP**，后续命令会用到。

### 步骤 3：运行相位补偿测试

```bash
# 方式 1：XS18 自环测试（XS18-XS19 短接）
RFSOC_BOARD_IP=169.254.21.60 RFSOC_TRIGGER_COUNT=100 \
    python3 -m software.dr47.examples.hardware_slave_phase_compensation_test
```

**预期输出（自环）**：
```
Phase slot distribution:
  slot 3: 100 triggers (100.0%)

✓ Self-loopback: phase_slot is stable (expected)
✓ phase_valid = 1 throughout test
✓ ILA spread = 0 (zero jitter)
```

**解释**：
- `phase_slot` **固定在某个值**（自环时相位恒定）
- `spread = 0` 证明补偿器工作正常

---

```bash
# 方式 2：外部触发测试（真实验证）
# 1. 断开 XS18-XS19 短接
# 2. 外部触发源 → XS19（~8ns 脉冲，任意时钟）
# 3. CH1 → 示波器

RFSOC_BOARD_IP=169.254.21.60 RFSOC_TRIGGER_COUNT=200 \
    python3 -m software.dr47.examples.hardware_slave_phase_compensation_test
```

**预期输出（外部触发）**：
```
Phase slot distribution:
  slot 0: 23 triggers (11.5%)
  slot 1: 27 triggers (13.5%)
  slot 2: 21 triggers (10.5%)
  slot 3: 29 triggers (14.5%)
  slot 4: 24 triggers (12.0%)
  slot 5: 26 triggers (13.0%)
  slot 6: 25 triggers (12.5%)
  slot 7: 25 triggers (12.5%)

✓ External trigger: phase_slot varies (expected)
✓ phase_valid = 1 throughout test
✓ ILA spread = 0 or 1 cycle (< 2.5 ns residual jitter)
```

**关键验证点**：
- ✅ `phase_slot` **在 0-7 之间随机分布**（外部触发时钟独立）
- ✅ `phase_valid = 1` 始终为真（相位测量有效）
- ✅ ILA `spread ≤ 1 cycle`（补偿后残余抖动 < 2.5 ns）

---

### 步骤 4：示波器最终确认

**示波器设置**：
- 触发：上升沿，0V 电平，**NORMAL 模式**（不是 AUTO）
- 时基：100 ns/div
- 采样率：≥4 GSa/s
- 显示：**余辉模式（Persistence）**

**预期结果**：
- 余辉图**完全叠加**，无散开
- 包络宽度 < 5 ns（60 ns 高斯）

**对比方案 A**：
- 方案 A（DAC 域直接捕获）：0 ns 抖动（但要求外部触发与 250 MHz 同步）
- 方案 B（200 MHz 测量补偿）：< 2.5 ns 抖动（外部触发完全独立）

---

## 如果测试失败

### 问题 1：`phase_slot` 始终为 0，`phase_valid = 0`

**原因**：200 MHz 时钟未运行

**解决**：
```bash
# 检查 IP 是否生成
ls hardware/vivado/work/custom_xczu47dr_slave_rfdc/custom_xczu47dr_slave_rfdc.gen/sources_1/ip/clk_gen_200mhz/

# 如果不存在，重新构建
cd hardware/vivado
make TARGET=custom_xczu47dr_slave clean
make TARGET=custom_xczu47dr_slave bitstream
```

### 问题 2：`phase_slot` 固定，但外部触发已断开

**原因**：XS18-XS19 仍然短接，或触发源意外与 DAC 时钟同步

**解决**：
- 物理检查 XS18-XS19 是否断开
- 用示波器测量外部触发源和 XS20（trigout 变体），确认它们**不同步**

### 问题 3：`phase_slot` 变化，但示波器仍有抖动

**原因**：补偿器未接入 `dac_trigger_request`

**检查 `Top.v:line ~1150`**：
```verilog
wire dac_trigger_request =
    IS_MASTER ? role_trigger_dac_pulse
              : (dac_direct_trigger_compensated |  // ← 应该用这个
                 (role_trigger_dac_pulse && !legacy_event_is_external_dac));
```

如果用的是 `dac_direct_trigger_pulse` 而不是 `dac_direct_trigger_compensated`，补偿器被旁路了。

### 问题 4：网络找不到板卡

**原因**：板卡未上电、IP 变化、或网口未连接

**解决**：
```bash
# 1. 检查网口状态
ip addr show enp1s0f0

# 应该看到 169.254.250.11/16

# 2. 扩大搜索范围
sudo nmap -sn 169.254.0.0/16 | grep -B2 "02:00"

# 3. 如果完全找不到，重新用 JTAG 加载
make TARGET=custom_xczu47dr_slave program
```

---

## 进一步测试

### 1. 长期稳定性测试

```bash
# 运行 1000 次触发
RFSOC_BOARD_IP=169.254.21.60 RFSOC_TRIGGER_COUNT=1000 \
    python3 -m software.dr47.examples.hardware_slave_phase_compensation_test
```

**检查**：
- `phase_slot` 分布是否均匀（每个 slot ~12.5%）
- `phase_valid` 是否始终为 1
- ILA `spread` 是否保持 ≤ 1 cycle

### 2. 不同触发频率测试

```bash
# 慢触发（1 Hz）
# 外部触发源设置为 1 Hz 重复频率

# 快触发（1 kHz）
# 外部触发源设置为 1 kHz 重复频率
```

**检查**：
- 方案 B 应该在所有频率下都稳定
- `phase_slot` 分布与触发频率无关

### 3. 温度测试（可选）

**如果有温箱**：
- −10°C、室温、+50°C 各运行 100 次触发
- 检查 `phase_slot` 分布和 ILA `spread` 是否变化

**预期**：
- MMCM 锁定稳定，相位测量准确性不受温度影响

---

## 切换到 250 MHz 分支（当铷钟到位后）

```bash
# 切换工作目录
cd /home/kyu/workspace/xczu47dr-rfdc-xs17-250mhz

# 构建 250 MHz bitstream（如果还没有）
make TARGET=custom_xczu47dr_slave bitstream

# 加载
make TARGET=custom_xczu47dr_slave program

# 运行相同的测试
RFSOC_BOARD_IP=<新IP> RFSOC_TRIGGER_COUNT=100 \
    python3 -m software.dr47.examples.hardware_slave_phase_compensation_test
```

**预期**：
- 250 MHz 分支的方案 B 行为与 10 MHz 分支完全一致
- 唯一差异：DAC 采样率（250 MHz 参考时钟 → 更高的 fs）

---

## 方案选择建议

### 使用方案 A（DAC 域直接捕获）
**条件**：
- ✅ 有 250 MHz 铷钟（与触发源共享）
- ✅ 需要极致性能（0 ns 抖动）

**优势**：
- 数字零抖动
- 资源消耗更少

**限制**：
- 外部触发必须与 DAC 时钟同步

### 使用方案 B（200MHz 相位补偿）
**条件**：
- ✅ 外部触发源独立（任意时钟）
- ✅ < 2.5 ns 抖动可接受

**优势**：
- 通用性强，无需硬件改造
- 软件可见相位（便于调试）

**限制**：
- 残余抖动 < 2.5 ns（对 60 ns 包络足够）

---

## 文档索引

- **快速导览**：`README_方案B.md`
- **技术详解**：`docs/方案B_相位补偿零抖动.md`
- **测试指南**：`docs/方案B_快速测试指南.md`
- **无 JTAG 测试**：`docs/方案B_无JTAG快速测试.md`
- **完整对比**：`docs/触发抖动问题完整解决方案_总结.md`

---

## 当前状态

✅ RTL 实现完成  
✅ 固件扩展完成  
✅ 软件驱动完成  
✅ Bitstream 构建完成  
✅ 文档完整  
✅ 代码已推送远程  

⏳ **等待 JTAG 连接进行硬件验证**

一旦 JTAG 连接，按照上面的 3 步流程，10 分钟内可以完成完整验证。
