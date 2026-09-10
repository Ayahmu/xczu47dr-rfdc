# 方案 B - 无需 JTAG 的快速网络测试流程

> 历史归档：本文的测试入口和命令已不再维护，请勿直接执行。
> 当前流程见 [Slave 外部 Trigger 快速上手](../快速上手_方案B.md)。

## 前提条件

1. **板卡已经运行某个旧版本的 bitstream**（有网络连接）
2. **10G 网口已连接**（`enp1s0f0` <-> 板卡）
3. **UART 线已连接**（可选，用于查看固件日志）

## 步骤 1：发现板卡当前 IP

```bash
cd /home/kyu/workspace/xczu47dr-rfdc

# 发现板卡
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

## 步骤 2：通过软件验证当前功能

假设发现的 IP 是 `169.254.21.60`，运行快速状态检查：

```bash
# 检查板卡状态（包括新增的 phase_slot 字段）
RFSOC_BOARD_IP=169.254.21.60 python3 - <<'PY'
import os
from dr47.device import RFSoCDevice

ip = os.environ.get("RFSOC_BOARD_IP")
dev = RFSoCDevice(ip, 1234, timeout_ms=2000)
dev.connect()

status = dev.status()
print(f"Board IP: {ip}")
print(f"Capabilities: 0x{status.capabilities:08X}")
print(f"Build profile: {status.build_profile}")
print(f"RFDC ready: {status.rfdc_ready}")
print(f"MTS ready: {status.dac_mts_ready}")

# 关键：检查新增字段
print(f"\n=== 方案 B 相位补偿字段 ===")
print(f"ext_trigger_phase_slot: {status.ext_trigger_phase_slot}")
print(f"ext_trigger_phase_valid: {status.ext_trigger_phase_valid}")

if hasattr(status, 'ext_trigger_phase_slot'):
    print("\n✓ 方案 B 字段存在（bitstream 支持相位补偿）")
else:
    print("\n✗ 方案 B 字段不存在（需要加载新 bitstream）")
PY
```

**预期输出**：
- 如果是**旧 bitstream**：`ext_trigger_phase_slot: 0`，`ext_trigger_phase_valid: 0`（默认值）
- 如果是**方案 B bitstream**：这两个字段会随着触发动态变化

## 步骤 3：运行相位补偿测试（方案 B bitstream 必需）

### 3a. XS18 自环测试（初步验证）

```bash
# XS18 和 XS19 短接
RFSOC_BOARD_IP=169.254.21.60 RFSOC_TRIGGER_COUNT=100 \
    python3 -m software.dr47.examples.hardware_slave_phase_compensation_test
```

**预期结果**：
```
Phase slot distribution:
  slot 3: 100 triggers (100.0%)

✓ Self-loopback: phase_slot is stable (expected)
✓ phase_valid = 1 throughout test
✓ ILA spread = 0 (zero jitter)
```

**解释**：
- `phase_slot` **固定在某个值**（比如 3）- 因为 XS18 和触发捕获在同一个时钟域
- `spread = 0` 证明补偿逻辑工作正常

### 3b. 外部触发测试（完整验证）

```bash
# 1. 断开 XS18-XS19 短接
# 2. 外部触发源 → XS19（8 ns 脉冲，任意时钟）
# 3. CH1 → 示波器

# 运行测试（手动触发 + 监控）
RFSOC_BOARD_IP=169.254.21.60 python3 - <<'PY'
import os
from dr47.device import RFSoCDevice
from dr47.upload import upload_waveform_file_simple
from dr47.constants import LOOP_FLAG

ip = os.environ.get("RFSOC_BOARD_IP")
dev = RFSoCDevice(ip, 1234, timeout_ms=2000)
dev.connect()

# 上传波形（60 ns 高斯 @ 1 GHz）
upload_waveform_file_simple(
    dev, "test_waveforms/gaussian_60ns_1000MHz.npz", 
    flags=0
)

# 设置到 bypass SYNC，等待外部触发
dev.bypass_sync()
print("Ready. Now trigger externally and monitor phase_slot...")

# 循环监控
for i in range(200):
    status = dev.status()
    print(f"[{i:3d}] phase_slot={status.ext_trigger_phase_slot}, "
          f"valid={status.ext_trigger_phase_valid}, "
          f"armed={status.armed}, running={status.running}")
    
    if not status.armed and not status.running:
        # 重新 arm
        dev.arm(run_id=i, channel_mask=0xFF)
    
    import time
    time.sleep(0.1)
PY
```

**预期结果**：
```
[  0] phase_slot=3, valid=1, armed=1, running=0
[  1] phase_slot=3, valid=1, armed=0, running=1   # 外部触发到达
[  2] phase_slot=5, valid=1, armed=1, running=0   # phase_slot 变化！
[  3] phase_slot=5, valid=1, armed=0, running=1
[  4] phase_slot=2, valid=1, armed=1, running=0   # 再次变化
...
```

**关键验证点**：
- ✅ `phase_slot` **在 0-7 之间随机变化**（外部触发时钟独立）
- ✅ `phase_valid = 1` 始终为真
- ✅ 示波器余辉模式下 CH1 **完全稳定**（无论 phase_slot 如何变化）

**如果失败**：
- `phase_slot` 固定 + `phase_valid = 0` → 200 MHz 时钟未运行（检查 `clk_gen_200mhz` IP）
- `phase_slot` 固定 + `phase_valid = 1` → 可能是自环（检查 XS18-XS19 是否断开）
- `phase_slot` 变化但示波器抖动 → 补偿器未接入（检查 `dac_trigger_request` 逻辑）

## 步骤 4：示波器验证（最终确认）

```bash
# 连接示波器
# CH1 = 板卡 TX_0（DAC Channel 1）
# Trigger = 板卡 XS20（如果用 trigout 变体）或外部触发源

# 设置示波器
# - 触发：上升沿，0V 电平，NORMAL 模式（不是 AUTO）
# - 时基：100 ns/div
# - 采样率：4 GSa/s 或更高
# - 显示：余辉模式（Persistence）

# 运行 100 次触发
RFSOC_BOARD_IP=169.254.21.60 RFSOC_TRIGGER_COUNT=100 \
    python3 -m software.dr47.examples.hardware_slave_phase_compensation_test
```

**预期结果**：
- **余辉图完全叠加**，无散开
- 包络宽度 < 5 ns（60 ns 高斯）
- 如果测量载波零交叉：< 10 ps

**与方案 A 对比**：
- 方案 A（DAC 域直接捕获）：抖动 0 ns（但要求外部触发与 DAC 时钟同步）
- 方案 B（200 MHz 测量 + 补偿）：抖动 < 2.5 ns（外部触发可以完全独立）

## 步骤 5：通过 ILA 验证（可选，需要 JTAG）

如果有 JTAG 连接，运行：

```bash
cd /home/kyu/workspace/xczu47dr-rfdc
python3 software/trigger_latency_report.py
```

**预期输出**：
```
=== Trigger Latency Report ===
Latency spread: 0 cycles (0.0 ns)
  min = 7, max = 7, last = 7

INTERPRETATION (TRIG_EMIT_DAC=0, external trigger):
✓ spread=0: 外部触发 + 相位补偿工作正常
  - phase_detector 测量准确
  - compensator 补偿到位
  - 残余抖动 < 2.5 ns（1 个 fabric cycle）
```

## 故障排查

### 问题 1：`phase_slot` 始终为 0，`phase_valid = 0`

**原因**：200 MHz 时钟未运行

**检查**：
```bash
# 1. 确认 clk_gen_200mhz IP 已生成
ls hardware/vivado/work/*/custom_xczu47dr_slave_rfdc.gen/sources_1/ip/clk_gen_200mhz/

# 2. 如果不存在，手动生成
cd hardware/vivado
vivado -mode batch -source scripts/clk_gen_200mhz.tcl
```

### 问题 2：`phase_slot` 固定，但外部触发已断开 XS18

**原因**：可能 XS18-XS19 仍然短接，或者触发源与 DAC 时钟意外同步

**检查**：
- 物理断开 XS18-XS19
- 用示波器测量外部触发源和 XS20 输出（trigout 变体），确认它们**不同步**

### 问题 3：`phase_slot` 变化，但示波器仍有抖动

**原因**：补偿器未接入 `dac_trigger_request`

**检查 `Top.v`**：
```verilog
wire dac_trigger_request =
    IS_MASTER ? role_trigger_dac_pulse
              : (dac_direct_trigger_compensated |  // ← 应该用这个
                 (role_trigger_dac_pulse && !legacy_event_is_external_dac));
```

### 问题 4：网络发现不到板卡

**原因**：
- 板卡未上电 / 未运行固件
- 网口未连接
- IP 地址变化（DNA 改变）

**解决**：
```bash
# 1. 检查网口
ip addr show enp1s0f0

# 2. 扩大搜索范围
sudo nmap -sn 169.254.0.0/16 | grep -B2 "02:00"

# 3. 如果完全找不到，需要 JTAG 加载
```

## 总结

方案 B 的核心优势是**通用性**：
- ✅ 外部触发源可以完全独立（任意时钟、任意相位）
- ✅ 抖动 < 2.5 ns（对于 60 ns 包络，这是完全可接受的）
- ✅ 无需修改外部硬件
- ✅ 软件可见相位测量（`phase_slot`），便于调试

方案 A 的核心优势是**极致性能**：
- ✅ 抖动 = 0 ns（数字零抖动）
- ✅ 资源消耗更少（无 200 MHz 时钟）
- ⚠️ 要求外部触发与 DAC 时钟同步（250 MHz 铷钟）

**生产环境建议**：
- 如果有 250 MHz 共享参考时钟 → **方案 A**
- 如果外部触发完全独立 → **方案 B**
- 不确定 → 先部署**方案 B**（通用解），性能不够再切换到方案 A
