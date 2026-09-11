# 驱动 SDK 交付指南

本文说明如何生成和使用 `47dr-driver` 安装包。当前版本为 `0.1.0`，要求
Python 3.10 或更高版本，仅支持 RFCTRL2 protocol v2。

当前交付不包含 TDC 校准、补偿和诊断接口。

## 1. 生成交付包

在仓库根目录执行：

```bash
make driver-release
```

成功后生成：

```text
dist/47dr_driver-0.1.0-py3-none-any.whl
dist/47dr-driver-sdk-0.1.0.zip
dist/SHA256SUMS
```

构建过程会从 wheel 运行模拟器样例，并确认发布 wheel 不包含 `dr47.tdc`。

## 2. ZIP 内容

```text
packages/       Python wheel
examples/       可直接运行的测试样例
docs/           API、使用和硬件验收文档
MANIFEST.json   版本、依赖、支持范围
SHA256SUMS      ZIP 内文件校验值
```

bitstream、ELF 和 LTX 不在驱动 SDK 中，应按目标板卡单独交付。至少提供：

```text
custom_xczu47dr_slave_trigout.bit
custom_xczu47dr_slave.elf
custom_xczu47dr_slave_trigout.ltx   # 需要 ILA 时
```

## 3. 接收方安装

解压 ZIP 后执行：

```bash
sha256sum -c SHA256SUMS

python3 -m venv .venv
source .venv/bin/activate
python -m pip install ./packages/47dr_driver-0.1.0-py3-none-any.whl
python -m dr47.examples.simulator_quickstart
```

最后一条命令输出 `driver simulation OK` 表示驱动、NumPy、波形生成和有限 burst
状态机可以正常运行。它不代表板卡硬件已经通过验收。

## 4. 样例

需要访问硬件的样例，其参数都位于文件顶部。先编辑常量，再无参数运行脚本。

| 样例 | 用途 |
| --- | --- |
| `simulator_quickstart.py` | 无板卡自检 |
| `network_discovery_example.py` | 只读发现板卡 |
| `single_board_software_trigger_example.py` | 软件 Trigger 发波 |
| `hardware_slave_bypass_external_trigger_test.py` | slave bypass 后等待 XS19 外部 Trigger |

推荐顺序：

```bash
python -m dr47.examples.simulator_quickstart
python examples/network_discovery_example.py
python examples/single_board_software_trigger_example.py
python examples/hardware_slave_bypass_external_trigger_test.py
```

完整接线、烧写和网络步骤见[使用与测试指南](使用与测试指南.md)。函数签名见
[API 参考](API参考.md)。

## 5. 支持范围

本版本支持：

- 板卡发现和静态网络配置；
- RFDC 频率、相位、输出增益和通道控制；
- CH1 至 CH8 波形上传；
- 软件 Trigger 和 XS19 外部 Trigger；
- 有限 burst 调度；
- 主从 SYNC 控制；
- 内存模拟器。

本版本不支持：

- TDC 校准、补偿和诊断；
- 用 Python 改变 bitstream 固化的 master/slave 电气角色；
- 用软件测试代替示波器或频谱仪验收。

## 6. 交付检查

交付前确认：

1. `make driver-release` 成功。
2. `cd dist && sha256sum -c SHA256SUMS` 成功。
3. wheel、bitstream 和 ELF 的版本匹配。
4. 已说明板卡 IP、主机网卡、XS17 参考频率和 XS19 接线。
5. 已记录实板测试和仪器验收结果。

仓库没有声明开源许可证。在对外公开发布前，需要补充许可证、版本策略和技术支持
联系方式。
