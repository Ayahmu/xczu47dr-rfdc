# 47DR Driver

开始实际联调前，请先阅读中文[驱动使用指南](../../docs/dr47_user_guide.md)，其中包含
安装、网络准备、板卡发现、波形播放、同步触发和验收预期。

完整 API 参考（函数签名、参数、返回值、CLI 和双板卡端到端示例）：
[`docs/dr47_api.md`](../../docs/dr47_api.md)。

Direct UDP driver for the XCZU47DR RFDC playback bitstream.  The package has
no web-server dependency and exposes `Dr47Device`, `SequenceGenerator`, and
`SimulatedDr47Device` through the `dr47` import name.

The direct-board smoke test keeps all network and waveform settings in
`hardware_wave_test.py` under `TEST_CONFIG`:

```bash
PYTHONPATH=software python -m dr47.hardware_wave_test
```

The test configuration uses `frequency_ghz` (or an explicit
`nco_frequency_ghz`), `baseband_frequency_ghz`, `sample_rate_ghz` and
`duration_ns`.  Four examples are included in
`EXAMPLES`: 100 ns/1 GHz one-shot sine, 60 ns/1.79 GHz one-shot Gaussian XY,
continuous 2 GHz sine, and 120 ns/1.5 GHz trigger-gated Gaussian XY.  Select
one with `ACTIVE_EXAMPLE` or edit `TEST_CONFIG` directly.

At the public API boundary, NCO frequencies are GHz:

```python
device.set_xy_nco_frequency(1, 1.79)
device.apply_rfdc_config(nco_ghz={1: 1.79})
```

The packet encoder still converts these values to RFCTRL2 integer Hz because
that is the firmware wire format.  For RF carriers above the 400 MS/s complex
baseband Nyquist limit, upload a DC or low-frequency IQ envelope and use the
NCO for the carrier.

## Single-SYNC and Trigger API

The connector contract is fixed: XS20 is the dedicated SYNC link, XS18
(`TRIG_1`) is output-only Trigger, and XS19 (`TRIG_2`) is input-only Trigger.
In formal `external` mode a slave accepts XS19 edges only after one physical
XS20 rising edge. The same SYNC epoch then covers subsequent Trigger edges; a
Trigger must not be accompanied by another SYNC pulse.

```python
device.set_sync_role("slave")
device.set_sync_mode("external")
# Upload a sequence that waits for Trigger, configure RFDC/output, then:
device.arm(channel_mask=0x01)
# XS20 rising edge arrives externally. Every later XS19 rising edge plays once.
status = device.status().capabilities
assert status.sync_seen and status.sync_link_ready
```

For a single-board physical loopback test, wire `XS18 -> XS19`, select the
explicit test bypass, and emit the Trigger through the real output connector:

```python
device.set_sync_role("slave")
device.set_sync_mode("self_test")  # No XS20 signal; not a timing sync.
device.arm(channel_mask=0x01)
device.emit_trigger()                  # XS18 -> cable -> XS19
```

`trigger()` is different: it is a local UDP software trigger and does not
drive XS18. `emit_trigger()` drives XS18 but does not directly start local
playback. Check `sync_seen`, `sync_link_ready`, `trigger_input_count`,
`trigger_accepted_count`, and `trigger_output_count` through
`device.status().capabilities` when commissioning the cable path.

## Switched multi-board enrollment

After programming a bitstream, boards boot with DNA-derived `169.254.x.y/16`
addresses. Put the host 10G interface on the same link-local network, then:

For a NetworkManager-managed Linux host, persist this host discovery address
once before using the workflow. Replace the connection name and interface with
the values from `nmcli connection show`; this adds an address and does not
remove existing addresses.

```bash
sudo nmcli connection modify "Wired connection 1" +ipv4.addresses "169.254.250.11/16"
sudo nmcli connection up "Wired connection 1"
ip address show dev enp225s0f1
```

The `169.254.0.0/16` direct route is created automatically. This persistent
setup avoids having to rerun `ip address replace` after reboot, network service
restart, or cable reconnection.

```bash
dr47-network prepare-interface --interface enp225s0f0 --source-ip 169.254.250.10/16
dr47-network discover --interface enp225s0f0 --source-ip 169.254.250.10 --json
dr47-network plan --interface enp225s0f0 --source-ip 169.254.250.10 \
  --ip-pool 10.50.0.101-10.50.0.120
```

Discovery is read-only. Assign a unique static address explicitly for each
`device_uid`; provisioning applies `NETWORK_APPLY`, restarts the board, and
verifies the new unicast address:

```bash
dr47-network provision --interface enp225s0f0 --source-ip 169.254.250.10 \
  --device-uid <UID> --ip 10.50.0.101 --mac 02:50:00:00:00:01
dr47-network status --interface enp225s0f0 --ip 10.50.0.101
```

Repeat this workflow after a bitstream reprogram. The workflow deliberately
does not use the legacy shared `192.168.254.254` bootstrap address. The switch
must pass broadcasts within the board VLAN; after provisioning, normal control
uses unicast IP addresses and UDP port 1234.
