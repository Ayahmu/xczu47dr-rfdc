"""082 主卡 / 081 从卡双板同步播放高斯包络正弦波测试。

硬件连接如下（触发线的方向不能接反）：

* 082 XS20 -> 081 XS20：板间同步（SYNC）链路。
* 082 XS18 -> 081 XS19：外部触发（Trigger）链路。
* 两块板的 XS17：接入同一个 10 MHz 参考时钟源。
* 082 和 081 分别接主机的两个 10GbE 网口；默认使用 ``enp1s0f1`` 和
  ``enp1s0f0``。以太网仅用于板卡发现、配置和波形上传，不代替板间同步线。

本例给两块板上传完全相同的有限长度 IQ 高斯包络正弦波。RF 载波由 RFDC NCO
产生，默认 NCO 为 1 GHz、IQ 基带为 20 MHz。IQ 复采样率为 400 MS/s，因此
基带频率的绝对值必须小于 200 MHz，否则会发生混叠。
"""

from __future__ import annotations

import time

import numpy as np

from ..capabilities import PlaybackState
from ..device import Dr47Device
from ..errors import DriverError
from ..hardware_test_network import BoardNetworkAssignment, discover_and_provision_boards
from ..waveforms import DAC_IQ_SAMPLE_RATE_HZ, make_iq_gaussian_sine_interleaved


# RFCTRL2 固件的 UDP 服务端口，发现板卡与后续控制均使用此端口。
BOARD_PORT = 1234

# 主卡和从卡各自使用一个独立的 10GbE 物理接口。这里直接固定为当前服务器
# 的实际接线：enp1s0f1 连接 082，enp1s0f0 连接 081。
MASTER_INTERFACE = "enp1s0f1"
MASTER_SOURCE_IP = "169.254.250.12"
MASTER_SOURCE_CIDR = "169.254.250.12/16"
SLAVE_INTERFACE = "enp1s0f0"
SLAVE_SOURCE_IP = "169.254.250.11"
SLAVE_SOURCE_CIDR = "169.254.250.11/16"
BROADCAST_IP = "169.254.255.255"

# 发现板卡后写入并用于控制的目标地址。两块板必须使用不同 IP。
MASTER_TARGET_IP = "169.254.100.101"
SLAVE_TARGET_IP = "169.254.100.102"
SUBNET_MASK = "255.255.0.0"
GATEWAY = "0.0.0.0"
# 留空表示依靠独立物理网口及固件报告的 master/slave 角色识别板卡。
MASTER_UID = ""
SLAVE_UID = ""

# 驱动通道从 1 开始编号，通道掩码则从 bit 0 开始，因此 CH1 对应 0x1。
CHANNEL = 1
CHANNEL_MASK = 1 << (CHANNEL - 1)

# NCO 决定 RF 载波中心频率，BASEBAND_FREQ_HZ 决定上传 IQ 波形的数字频偏。
# 本例输出的主要频率分量由二者共同决定，具体上/下边带取决于 RFDC 混频配置。
NCO_GHZ = 1.0
BASEBAND_FREQ_HZ = 20_000_000.0
# AMPLITUDE 是 int16 IQ 采样幅度；GAIN 是写入板卡的归一化数字增益。
AMPLITUDE = 12_000
GAIN = 1.0
# DURATION_S 只决定高斯脉冲的有效时长；RECORD_COMPLEX_SAMPLES 决定整条记录
# 的长度。记录必须容纳完整脉冲，剩余区域为零填充。
DURATION_S = 200e-9
PHASE_RAD = 0.0
RECORD_COMPLEX_SAMPLES = 16_384
# 运行脚本前应先把示波器置于 Single/Armed；这里无需额外等待。
SCOPE_ARM_DELAY_S = 0.0
# 触发后只保留 1 秒供示波器读取，随后 finally 会停止并静音板卡。
SCOPE_OBSERVE_S = 1.0


def _wait_state(device: Dr47Device, expected: PlaybackState, label: str) -> None:
    """等待板卡真正进入目标播放状态，最多等待 5 秒。

    UDP 命令成功返回只代表命令已被接收，硬件状态机切换仍可能有很短延迟，因此
    测试必须轮询状态，而不能在命令返回后立即假定 ARM/Trigger 已完成。
    """
    deadline = time.monotonic() + 5.0
    last = None
    while time.monotonic() < deadline:
        last = device.status(refresh=True)
        if last.state is expected:
            return
        time.sleep(0.02)
    actual = "unknown" if last is None else last.state.value
    raise AssertionError(f"{label}: expected {expected.value}, got {actual}")


def _wait_trigger_accepted(device: Dr47Device, before_count: int, label: str):
    """等待 Trigger accepted 计数增加，并返回触发后的最新状态。

    单次波形只持续几十微秒，软件通常来不及读到瞬时 RUNNING。因此一次性测试
    应以固件锁存的 accepted 计数为准，而不是要求状态轮询刚好命中 RUNNING。
    """
    deadline = time.monotonic() + 3.0
    last = None
    while time.monotonic() < deadline:
        last = device.status(refresh=True)
        if last.capabilities.trigger_accepted_count > before_count:
            return last
        time.sleep(0.01)
    actual = 0 if last is None else last.capabilities.trigger_accepted_count
    raise AssertionError(f"{label}: Trigger accepted 计数未增加（{before_count} -> {actual}）")


def _trigger_master_and_emit_xs18(master: Dr47Device) -> None:
    """连续下发主卡本地启动和 XS18 输出，不在两条命令之间等待响应。

    RFCTRL2 当前没有“本地 Trigger + XS18 输出”的单个原子 opcode；如果使用
    ``master.trigger()`` / ``master.emit_trigger()``，每个调用都会等待 UDP 响应，
    两次往返之间会产生几十到几百微秒的 Python/网络间隔。这里直接使用底层
    ``wait_response=False`` 接口，在同一个 UDP socket 上连续发送两包。UDP 对同一
    目标的发送顺序保持不变，板卡会先收到本地播放命令，再收到 XS18 输出命令，
    不把 Python 调度延迟带入板间同步时序。
    """
    master.rfctrl2_trigger(wait_response=False)
    master.rfctrl2_emit_trigger(wait_response=False)


def _new_device(ip: str, interface: str, source_ip: str) -> Dr47Device:
    """为一块板创建绑定到指定物理网口和源 IP 的 UDP 驱动对象。"""
    return Dr47Device(
        ip=ip,
        port=BOARD_PORT,
        udp_interface=interface,
        udp_source_ip=source_ip,
        timeout_s=1.0,
        retries=2,
        batch_mode=True,
    )


def _make_one_shot_trigger_sequence(sample_count: int) -> np.ndarray:
    """生成“等待一次 Trigger -> 播放一条记录 -> 停止”的单次序列。

    序列不含 LS/LE 循环指令，因此板卡收到 Trigger 后只输出一次波形。即使之后
    XS19 再出现触发边沿，也不会在没有重新上传和 ARM 的情况下重复播放。
    """
    count = int(sample_count)
    if not 1 <= count <= 0xFFFF:
        raise ValueError("单次 Trigger 序列的采样点数必须在 1..65535 范围内")
    return np.asarray(
        [
            [0, count, 0, 0x4000],  # TR：等待一次 Trigger
            [0, count, 0, 0x0000],  # DI：播放一次完整 IQ 记录
            [0, count, 0, 0x8000],  # ST：播放完成后停止
        ],
        dtype="<u2",
    )


def _configure_and_arm(device: Dr47Device, waveform: np.ndarray, label: str) -> None:
    """配置一块板、上传 CH1 波形并 ARM，但暂不启动播放。

    两块板必须先后完成此步骤并停在 PREPARED，随后才能用同一个 SYNC 时基和
    硬件 Trigger 启动。波形采用 ``I0,Q0,I1,Q1,...`` 的交错 IQ 存储格式。
    单次序列不包含硬件循环，播放完一条记录后即停止。
    """
    # 配置 CH1 的 RFDC NCO、数字增益和正交校正，并一次性提交到硬件。
    device.set_xy_nco_frequency(CHANNEL, NCO_GHZ)
    device.set_gain("xy", CHANNEL, GAIN, gain_type="norm")
    device.set_qc_on_off("xy", CHANNEL, "on")
    device.commit()
    # 一个复采样点包含 I/Q 两个 int16 数值，所以复采样点数是数组长度的一半。
    complex_count = int(waveform.size // 2)
    # auto_start=False 保证上传后不会立即播放；loop=False 和单次 Trigger 序列共同
    # 保证 DAC 只输出一条记录。单次序列的控制包也必须只提交一次；重复提交会在
    # 当前固件的指令队列中留下多份 END，导致 Trigger 后仍停在 ARMED。
    device.upload_waveforms(
        {CHANNEL: waveform},
        channel_sequences={CHANNEL: _make_one_shot_trigger_sequence(complex_count)},
        wave_formats={CHANNEL: "interleaved_iq"},
        auto_start=False,
        loop=False,
        instruction_repeats=1,
    )
    # 只 ARM CH1，并确认固件状态机已经进入 PREPARED。
    device.arm(channel_mask=CHANNEL_MASK)
    _wait_state(device, PlaybackState.PREPARED, f"{label} ARM")


def run() -> int:
    """执行一次双板发现、配置、同步、触发和结果校验。"""
    master = None
    slave = None
    try:
        # 1. 从 082 对应网口广播 NETWORK_GET，识别主卡并配置其控制 IP。
        # 若设置了 MASTER_UID，还会用 UID 防止误把另一块板配置成主卡。
        master_net = discover_and_provision_boards(
            [BoardNetworkAssignment("082主卡", "master", MASTER_TARGET_IP, device_uid=MASTER_UID,
                                    subnet_mask=SUBNET_MASK, gateway=GATEWAY)],
            interface=MASTER_INTERFACE,
            discovery_source_ip=MASTER_SOURCE_IP,
            discovery_source_cidr=MASTER_SOURCE_CIDR,
            control_source_ip=MASTER_SOURCE_IP,
            broadcast_ip=BROADCAST_IP,
            port=BOARD_PORT,
        )[0]
        # 2. 从另一物理网口独立发现 081，并配置为从卡控制 IP。
        slave_net = discover_and_provision_boards(
            [BoardNetworkAssignment("081从卡", "slave", SLAVE_TARGET_IP, device_uid=SLAVE_UID,
                                    subnet_mask=SUBNET_MASK, gateway=GATEWAY)],
            interface=SLAVE_INTERFACE,
            discovery_source_ip=SLAVE_SOURCE_IP,
            discovery_source_cidr=SLAVE_SOURCE_CIDR,
            control_source_ip=SLAVE_SOURCE_IP,
            broadcast_ip=BROADCAST_IP,
            port=BOARD_PORT,
        )[0]
        # 3. 分别建立两条 UDP 控制连接，并检查 bitstream 角色及 RFDC 初始化状态。
        master = _new_device(master_net.ip, MASTER_INTERFACE, MASTER_SOURCE_IP)
        slave = _new_device(slave_net.ip, SLAVE_INTERFACE, SLAVE_SOURCE_IP)
        master.connect()
        slave.connect()
        for device, label, role in ((master, "082主卡", "master"), (slave, "081从卡", "slave")):
            status = device.status(refresh=True)
            caps = status.capabilities
            print(f"{label}: role={caps.sync_role}, RFDC={caps.rfdc_ready}, MTS={caps.dac_mts_ready}, "
                  f"NCO={caps.nco_sync_ready}, sync={caps.sync_seen}/{caps.sync_link_ready}")
            # 烧写错误的 master/slave bitstream 会导致同步方向错误，立即终止测试。
            if caps.sync_role != role:
                raise AssertionError(f"{label} role mismatch: {caps.sync_role}")
            if not (caps.rfdc_ready and caps.dac_mts_ready and caps.nco_sync_ready):
                raise AssertionError(f"{label} RFDC/MTS/NCO is not ready")
            # 清理上一次测试可能遗留的 PREPARED/RUNNING 状态，再强制使用外部同步。
            if status.state is not PlaybackState.IDLE:
                device.abort_mute()
            device.require_external_sync()

        # 4. 校验波形长度。固件记录长度字段是 16 bit，并要求底层 int16 数据按
        # 16 个元素对齐；raw_count 是包含 I/Q 两路在内的 int16 元素总数。
        if not 1 <= RECORD_COMPLEX_SAMPLES <= 0xFFFF:
            raise ValueError("代码常量 RECORD_COMPLEX_SAMPLES 必须在 1..65535 范围内")
        active_complex_count = max(16, int(round(DURATION_S * DAC_IQ_SAMPLE_RATE_HZ)))
        if RECORD_COMPLEX_SAMPLES < active_complex_count:
            raise ValueError("Gaussian record is shorter than the active pulse")
        raw_count = ((RECORD_COMPLEX_SAMPLES * 2 + 15) // 16) * 16
        # 生成两块板共用的交错 IQ 波形。hls_xy_drag=False 表示这里不额外应用
        # HLS XY 拖尾处理，保持测试波形和指定高斯包络一致。
        waveform = make_iq_gaussian_sine_interleaved(
            BASEBAND_FREQ_HZ,
            PHASE_RAD,
            AMPLITUDE,
            DAC_IQ_SAMPLE_RATE_HZ,
            DURATION_S,
            sample_count=raw_count,
            hls_xy_drag=False,
        )
        print(f"Gaussian sine: NCO={NCO_GHZ:g} GHz, baseband={BASEBAND_FREQ_HZ:g} Hz, "
              f"duration={DURATION_S * 1e9:g} ns, record_samples={raw_count // 2}")
        print("CH1 output is vout00 differential (vout00_v_p/vout00_v_n); "
              "connect a suitable differential RF probe before triggering")
        # 5. 上传相同数据并让两块板都停在 PREPARED，等待后续同步和触发。
        _configure_and_arm(master, waveform, "082主卡")
        _configure_and_arm(slave, waveform, "081从卡")

        # 6. 082 从 XS20 发出带 epoch=1 的同步事件；轮询 081，确认它确实从
        # XS20 看到了同步事件且同步链路处于 ready，而不只检查 UDP 命令返回值。
        master.sync(epoch=1)
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            sync_caps = slave.status(refresh=True).capabilities
            if sync_caps.sync_seen and sync_caps.sync_link_ready:
                break
            time.sleep(0.02)
        else:
            raise AssertionError("081从卡没有观察到 082主卡 XS20 SYNC")

        # 7. 暂停以便示波器进入 Armed。CH1 是 vout00_v_p/vout00_v_n 差分输出，
        # 应使用合适的差分 RF 测量方式；不能用普通单端地夹直接跨接差分 DAC。
        print(f"请在 {SCOPE_ARM_DELAY_S:g} 秒内 armed 示波器，然后开始一次同步发波")
        time.sleep(max(0.0, SCOPE_ARM_DELAY_S))
        # 8. 在同一个 UDP socket 上连续发送两条不等待响应的命令：先启动 082
        # 本地播放，紧接着从 082 XS18 输出物理 Trigger 到 081 XS19。两条命令
        # 之间不再插入 status() 或 Python 等待，避免产生约 100 us 的软件间隔。
        before = slave.status(refresh=True).capabilities
        _trigger_master_and_emit_xs18(master)
        slave_after = _wait_trigger_accepted(
            slave,
            before.trigger_accepted_count,
            "081从卡 XS19 trigger",
        )
        after = slave_after.capabilities
        # input_count 增加说明 XS19 检测到电平；accepted_count 增加说明该脉冲在
        # PREPARED 状态被播放状态机接受。两个计数都增加才算硬件触发链路通过。
        print(f"081从卡 Trigger input/accepted: {before.trigger_input_count}/"
              f"{before.trigger_accepted_count} -> {after.trigger_input_count}/"
              f"{after.trigger_accepted_count}")
        if after.trigger_input_count <= before.trigger_input_count:
            raise AssertionError("081从卡 XS19 input counter did not increase")
        if after.trigger_accepted_count <= before.trigger_accepted_count:
            raise AssertionError("081从卡 did not accept the physical Trigger")
        # 9. 波形只在 Trigger 后输出一次；保留短暂观察时间，避免 finally 立即
        # 清理状态，同时不会像原来的长时间等待那样让程序看起来卡住。
        print(f"单次波形已经发送完成，观察 {SCOPE_OBSERVE_S:g} 秒；"
              "示波器应在 vout00 捕获到一次高斯正弦包络")
        time.sleep(SCOPE_OBSERVE_S)
        print("PASS: 082 master and 081 slave synchronized and played the same Gaussian-sine waveform")
        return 0
    except (DriverError, AssertionError, ValueError) as error:
        print(f"FAIL: {type(error).__name__}: {error}")
        return 2
    finally:
        # 无论成功、断言失败还是驱动异常，都停止并静音两块板，然后关闭 socket，
        # 避免测试结束后残留输出状态影响下一次运行。
        for device in (slave, master):
            if device is None:
                continue
            try:
                if device.connected:
                    device.abort_mute()
            except DriverError:
                pass
            device.close()


if __name__ == "__main__":
    raise SystemExit(run())
