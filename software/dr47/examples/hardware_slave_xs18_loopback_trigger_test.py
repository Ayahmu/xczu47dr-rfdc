"""单板 slave bypass + XS19 外部 Trigger 测试脚本。

对应 ``custom_xczu47dr_slave_trigout`` bitstream 的接线：

    XS17 -> 10 MHz 参考
    外部 Trigger 源 -> XS19
    XS20 -> 示波器 Trigger 时间基准（该 bitstream 中 XS20 不是 SYNC 输入）
    CH1/CH2 -> 示波器或后级 50 Ω 端接

脚本直连 ``BOARD_IP``，连接后先停止上一次可能残留的播放，再强制调用一次
``bypass_sync()``。之后把同一条有限高斯脉冲串上传到 CH1 和 CH2 并 ARM；脚本
不会调用 ``trigger()`` 或 ``emit_trigger()``，只等待 XS19 的物理上升沿。每个被
接受的外部 Trigger 同时播放两个通道的一整串 Gaussian，脉冲串的首脉冲延迟、
脉冲间隔和脉冲个数由文件顶部的 ``BURST_DELAY_NS``、``BURST_INTERVAL_NS``、
``BURST_COUNT`` 设置。按 Ctrl-C 退出时会尽力执行 ``ABORT_MUTE``，避免下次网络
配置因板卡仍处于 ARM 状态而收到 ``NETWORK_APPLY 0x0006``。

``TRIGGER_COUNT`` 只控制本轮等待多少个**被接受**的外部 Trigger；输入计数和
接受计数都会打印，若外部源过快导致超过目标或丢失记录，脚本会报告原因。跑完
之后可用 ``software/trigger_latency_report.py`` 读取 ILA 中累计的延迟测量值。
"""

from __future__ import annotations

import os
import time

import numpy as np

from ..capabilities import PlaybackState
from ..device import Dr47Device
from ..errors import DriverError
from ..playback import BurstSchedule
from . import _common as common


PLOT_RECORD_PATH = os.environ.get("RFSOC_RECORD_PLOT_PATH", "record_preview.png")
PLOT_MAX_POINTS = int(os.environ.get("RFSOC_RECORD_PLOT_POINTS", "20000"))
PLOT_ZOOM_NS = float(os.environ.get("RFSOC_RECORD_PLOT_ZOOM_NS", "5000.0"))


def _plot_record(
    record: np.ndarray,
    *,
    sample_rate_hz: float,
    output_path: str = PLOT_RECORD_PATH,
    max_points: int = PLOT_MAX_POINTS,
    zoom_ns: float = PLOT_ZOOM_NS,
) -> str | None:
    """Save an interleaved-IQ record preview and return its path.

    The full-record view uses per-bin min/max envelopes, so a sparse Gaussian
    burst remains visible even when the record is hundreds of milliseconds
    long. The second view plots raw I/Q samples from the first ``zoom_ns``.
    """

    try:
        import matplotlib

        matplotlib.use("TkAgg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("WARNING: matplotlib is not installed; skipping record plot")
        return None

    raw = np.asarray(record, dtype=np.int16).reshape(-1)
    if raw.size == 0 or raw.size % 2:
        raise ValueError("record must contain a non-empty even number of int16 lanes")
    if float(sample_rate_hz) <= 0.0:
        raise ValueError("sample_rate_hz must be positive")
    if int(max_points) <= 0:
        raise ValueError("max_points must be positive")
    if float(zoom_ns) <= 0.0:
        raise ValueError("zoom_ns must be positive")

    i_data = raw[0::2]
    q_data = raw[1::2]
    complex_count = int(i_data.size)
    bin_count = min(int(max_points), complex_count)
    # Preserve extrema in each bin instead of selecting evenly spaced points;
    # otherwise narrow pulses disappear from a long sparse record.
    full_x = np.empty(bin_count, dtype=np.float64)
    i_min = np.empty(bin_count, dtype=np.int16)
    i_max = np.empty(bin_count, dtype=np.int16)
    q_min = np.empty(bin_count, dtype=np.int16)
    q_max = np.empty(bin_count, dtype=np.int16)
    for index in range(bin_count):
        start = index * complex_count // bin_count
        end = max(start + 1, (index + 1) * complex_count // bin_count)
        i_chunk = i_data[start:end]
        q_chunk = q_data[start:end]
        full_x[index] = ((start + end - 1) * 0.5) / float(sample_rate_hz) * 1e9
        i_min[index], i_max[index] = i_chunk.min(), i_chunk.max()
        q_min[index], q_max[index] = q_chunk.min(), q_chunk.max()

    zoom_count = min(
        complex_count,
        max(1, int(round(float(zoom_ns) * 1e-9 * float(sample_rate_hz)))),
    )
    zoom_x = np.arange(zoom_count, dtype=np.float64) / float(sample_rate_hz) * 1e9
    envelope = np.hypot(i_data[:zoom_count].astype(np.float64), q_data[:zoom_count])

    figure, (full_axis, zoom_axis) = plt.subplots(
        2, 1, figsize=(14, 9), constrained_layout=True
    )
    full_axis.fill_between(full_x, i_min, i_max, alpha=0.25, color="tab:blue")
    full_axis.plot(full_x, i_min, color="tab:blue", linewidth=0.7, label="I min")
    full_axis.plot(full_x, i_max, color="tab:blue", linewidth=0.7, label="I max")
    full_axis.plot(full_x, q_min, color="tab:orange", linewidth=0.7, label="Q min")
    full_axis.plot(full_x, q_max, color="tab:orange", linewidth=0.7, label="Q max")
    full_axis.set_title(f"Record full preview ({complex_count:,} IQ samples)")
    full_axis.set_xlabel("Time (ns)")
    full_axis.set_ylabel("int16")
    full_axis.grid(True, alpha=0.3)
    full_axis.legend(ncol=2)

    zoom_axis.plot(zoom_x, i_data[:zoom_count], label="I", color="tab:blue")
    zoom_axis.plot(zoom_x, q_data[:zoom_count], label="Q", color="tab:orange")
    zoom_axis.plot(zoom_x, envelope, label="|IQ|", color="tab:green", alpha=0.8)
    zoom_axis.set_title(f"Record zoom (first {zoom_count:,} IQ samples)")
    zoom_axis.set_xlabel("Time (ns)")
    zoom_axis.set_ylabel("int16")
    zoom_axis.grid(True, alpha=0.3)
    zoom_axis.legend()

    parent = os.path.dirname(os.path.abspath(output_path))
    os.makedirs(parent, exist_ok=True)
    # figure.savefig(output_path, dpi=150)
    plt.show(block=True)
    print(f"[plot] record plot saved: {output_path}")
    return output_path


def _prepare_gaussian_waveform(
    device: Dr47Device,
    *,
    rf_nco_frequency_ghz: float,
    baseband_frequency_ghz: float,
    duration_ns: float,
    delay_ns: float,
    record_duration_ns: float | None,
    amplitude: float,
    gain: float,
    loop: bool,
    sample_rate_hz: float = 400_000_000.0,
    phase_rad: float = 0.0,
    interval_ns: float = 1_000.0,
    pulse_count: int = 1,
    fwhm_ns: float | None = None,
    bulk_upload: bool = False,
    label: str = "external-trigger",
) -> None:
    """配置 CH1/CH2、上传同一条有限高斯脉冲串并 ARM。"""

    if loop:
        raise ValueError("burst schedule owns loop control; loop must be False")
    # The legacy helper ``make_gaussian_burst_record`` is intentionally not
    # used here: it materializes c pulses in DDR. The new path keeps one pulse
    # record and lets the FPGA schedule c repetitions.
    record = common.make_gaussian_record(
        rf_nco_frequency_ghz=rf_nco_frequency_ghz,
        baseband_frequency_ghz=baseband_frequency_ghz,
        duration_ns=duration_ns,
        delay_ns=0.0,
        record_duration_ns=duration_ns,
        amplitude=amplitude,
        sample_rate_hz=sample_rate_hz,
        phase_rad=phase_rad,
        fwhm_ns=fwhm_ns,
    )
    effective_fwhm_ns = duration_ns / 2.0 if fwhm_ns is None else fwhm_ns
    print(
        f"{label} 脉冲串参数：a={delay_ns:g} ns，b={interval_ns:g} ns，"
        f"c={pulse_count}，Gaussian FWHM={effective_fwhm_ns:g} ns，"
        f"单脉冲记录约 {len(record) / 2 / sample_rate_hz * 1e9:g} ns，DDR 只存 1 份"
    )
    _plot_record(record, sample_rate_hz=sample_rate_hz)
    # channels=(1, 2) share one DDR record and one common schedule.  This is
    # the scheduled equivalent of the legacy common.configure_and_arm helper.
    for channel in (1, 2):
        device.set_xy_target_frequency(channel, rf_nco_frequency_ghz)
        device.set_gain("xy", channel, gain, gain_type="norm")
        device.set_qc_on_off("xy", channel, "on")
    device.commit()
    device.configure_playback(
        {1: record, 2: record},
        schedule=BurstSchedule(delay_ns, interval_ns, pulse_count),
        wave_formats={1: "interleaved_iq", 2: "interleaved_iq"},
        channel_mask=0x03,
        bulk_upload=bulk_upload,
    )
    device.arm_playback(channel_mask=0x03)


BOARD_IP = os.environ.get("RFSOC_BOARD_IP", "169.254.149.60")
BOARD_PORT = 1234
UDP_INTERFACE = os.environ.get("RFSOC_UDP_INTERFACE", "enp1s0f0")
CONTROL_SOURCE_IP = os.environ.get("RFSOC_CONTROL_SOURCE_IP", "169.254.250.11")

TRIGGER_COUNT = int(os.environ.get("RFSOC_TRIGGER_COUNT", "20000"))
TRIGGER_POLL_INTERVAL_S = float(
    os.environ.get("RFSOC_TRIGGER_POLL_INTERVAL_S", "0.02")
)

RF_NCO_GHZ = float(os.environ.get("RFSOC_RF_NCO_GHZ", "4.9385"))
# Gaussian active window and FWHM are separate. Keep a 60 ns window so the
# requested 30 ns FWHM has low-amplitude tails instead of being cut at half
# height at both ends of the finite record.
GAUSSIAN_NS = float(os.environ.get("RFSOC_GAUSSIAN_NS", "30.0"))
GAUSSIAN_FWHM_NS = float(os.environ.get("RFSOC_GAUSSIAN_FWHM_NS", "15.0"))
# a: Trigger -> first Gaussian start; b: start-to-start interval; c: count.
BURST_DELAY_NS = float(os.environ.get("RFSOC_BURST_DELAY_NS", "389"))
BURST_INTERVAL_NS = float(os.environ.get("RFSOC_BURST_INTERVAL_NS", "400000.0"))
BURST_COUNT = int(os.environ.get("RFSOC_BURST_COUNT", "1200"))
_record_ns_text = os.environ.get(
    "RFSOC_BURST_RECORD_NS", os.environ.get("RFSOC_RECORD_NS")
)
BURST_RECORD_NS = None if _record_ns_text is None else float(_record_ns_text)

_COUNTER_MASK = 0xFFFFFFFF


def _counter_delta(current: int, before: int) -> int:
    """Return a 32-bit hardware counter delta, including one wraparound."""

    return (int(current) - int(before)) & _COUNTER_MASK


def _counts(device: Dr47Device, label: str):
    status = device.status(refresh=True)
    caps = status.capabilities
    print(
        f"{label}: 状态={status.state.value} "
        f"角色={caps.sync_role} 模式={caps.sync_mode} "
        f"门控={caps.sync_link_ready} "
        f"Trigger(输入/接受/输出)={caps.trigger_input_count}/"
        f"{caps.trigger_accepted_count}/{caps.trigger_output_count}"
    )
    return caps


def _validate_config() -> None:
    if int(TRIGGER_COUNT) <= 0:
        raise ValueError("RFSOC_TRIGGER_COUNT must be positive")
    if float(TRIGGER_POLL_INTERVAL_S) <= 0.0:
        raise ValueError("RFSOC_TRIGGER_POLL_INTERVAL_S must be positive")
    if float(GAUSSIAN_NS) <= 0.0 or float(GAUSSIAN_FWHM_NS) <= 0.0:
        raise ValueError("Gaussian duration and FWHM must be positive")
    if float(BURST_DELAY_NS) < 0.0:
        raise ValueError("RFSOC_BURST_DELAY_NS must be non-negative")
    if float(BURST_INTERVAL_NS) <= 0.0:
        raise ValueError("RFSOC_BURST_INTERVAL_NS must be positive")
    if int(BURST_COUNT) <= 0:
        raise ValueError("RFSOC_BURST_COUNT must be positive")
    if BURST_RECORD_NS is not None and float(BURST_RECORD_NS) <= 0.0:
        raise ValueError("RFSOC_BURST_RECORD_NS must be positive")


def _wait_external_triggers(
    device: Dr47Device,
    *,
    before_input: int,
    before_accepted: int,
) -> tuple[int, int]:
    """Wait for exactly ``TRIGGER_COUNT`` accepted XS19 edges."""

    target = int(TRIGGER_COUNT)
    last_input = 0
    last_accepted = 0
    warned_unaccepted = False
    print(
        f"已 ARM，等待 {target} 次 XS19 外部 Trigger；"
        "本脚本不会发送软件或 XS18 Trigger"
    )
    while True:
        caps = device.status(refresh=True).capabilities
        input_delta = _counter_delta(caps.trigger_input_count, before_input)
        accepted_delta = _counter_delta(caps.trigger_accepted_count, before_accepted)

        if accepted_delta > target:
            raise RuntimeError(
                f"XS19 接受计数已超过目标：{accepted_delta}>{target}；"
                "请降低外部 Trigger 频率"
            )
        if input_delta > target:
            raise RuntimeError(
                f"XS19 输入计数已超过目标：{input_delta}>{target}；"
                "请降低外部 Trigger 频率，避免目标之后仍有脉冲到达"
            )
        if input_delta != last_input or accepted_delta != last_accepted:
            print(
                f"XS19 Trigger 输入/接受={input_delta}/{accepted_delta}/{target}",
                flush=True,
            )
            last_input = input_delta
            last_accepted = accepted_delta

        if input_delta > accepted_delta and not warned_unaccepted:
            print(
                "WARNING: 有 XS19 Trigger 到达时播放器尚未 PREPARED，"
                "这些事件不会排队"
            )
            warned_unaccepted = True

        if accepted_delta == target:
            return input_delta, accepted_delta
        time.sleep(TRIGGER_POLL_INTERVAL_S)


def run() -> int:
    """连接 slave、旁路 SYNC、ARM 后等待 XS19 外部 Trigger。"""

    _validate_config()
    device = Dr47Device(
        ip=BOARD_IP,
        port=BOARD_PORT,
        udp_interface=UDP_INTERFACE,
        udp_source_ip=CONTROL_SOURCE_IP,
        timeout_s=2.0,
        retries=3,
    )
    try:
        device.connect()
        print(f"已连接 {BOARD_IP}:{BOARD_PORT} via {UDP_INTERFACE}")

        # 先清理上一次脚本可能遗留的 ARM/RUNNING 状态；这也让后续 RFDC_APPLY
        # 和重新运行其它网络测试时不会被 NETWORK_APPLY 0x0006 卡住。
        device.abort_mute()
        initial = _counts(device, "清理后")
        if initial.sync_role != "slave":
            raise AssertionError(
                f"需要 slave bitstream，实际为 {initial.sync_role!r}"
            )
        common.wait_rfdc_ready(device, "从卡")

        # slave_trigout 没有 XS20 SYNC 输入；每次运行都明确设置 bypass，不能
        # 依赖上一次连接留下的模式。
        device.bypass_sync()
        bypass = _counts(device, "bypass_sync() 后")
        if bypass.sync_mode != "bypass":
            raise AssertionError("bypass_sync() 后同步模式不是 bypass")
        if bypass.sync_seen:
            raise AssertionError("bypass 不得伪造 sync_seen=True")
        if not bypass.sync_link_ready:
            raise AssertionError("bypass 后 XS19 Trigger 门控未打开")

        _prepare_gaussian_waveform(
            device,
            rf_nco_frequency_ghz=RF_NCO_GHZ,
            baseband_frequency_ghz=0.0,
            duration_ns=GAUSSIAN_NS,
            delay_ns=BURST_DELAY_NS,
            record_duration_ns=BURST_RECORD_NS,
            amplitude=0.7,
            gain=1.0,
            loop=False,
            sample_rate_hz=400_000_000.0,
            phase_rad=0.0,
            interval_ns=BURST_INTERVAL_NS,
            pulse_count=BURST_COUNT,
            fwhm_ns=GAUSSIAN_FWHM_NS,
            bulk_upload=True,
            label="从卡外部 Trigger",
        )
        armed = _counts(device, "上传并 ARM 后")
        if device.status(refresh=False).state is not PlaybackState.PREPARED:
            raise AssertionError("ARM 之后没有进入 PREPARED")

        before_input = armed.trigger_input_count
        before_accepted = armed.trigger_accepted_count
        _wait_external_triggers(
            device,
            before_input=before_input,
            before_accepted=before_accepted,
        )

        # 接受计数在启动时增加；等待有限记录播放完毕，避免清理动作截断最后一条。
        burst_duration_s = (
            (float(BURST_DELAY_NS)
             + max(0, int(BURST_COUNT) - 1) * float(BURST_INTERVAL_NS)
             + float(GAUSSIAN_NS))
            * 1e-9
        )
        common.wait_state(
            device,
            PlaybackState.PREPARED,
            "最后一条外部 Trigger 波形完成",
            timeout_s=max(10.0, burst_duration_s + 5.0),
        )
        final = _counts(device, "本轮结束")
        d_in = _counter_delta(final.trigger_input_count, before_input)
        d_acc = _counter_delta(final.trigger_accepted_count, before_accepted)
        print(f"本轮增量：XS19 输入={d_in}  接受={d_acc}  XS18 输出=0")
        if d_acc != int(TRIGGER_COUNT):
            print(f"FAIL: 外部 Trigger 接受数 {d_acc} != 目标 {TRIGGER_COUNT}")
            return 2
        print("PASS: bypass SYNC 后完成指定数量的 XS19 外部 Trigger 播放")
        print("接着运行以读取 ILA 里的延迟实测值：")
        print("  python3 software/trigger_latency_report.py --role slave_trigout \\")
        print("      --jtag-serial 210512180082 \\")
        print("      --ltx artifacts/custom_xczu47dr_slave_trigout.ltx")
        return 0
    except KeyboardInterrupt:
        print("收到 Ctrl-C，停止等待并静音")
        return 0
    except (DriverError, AssertionError, RuntimeError, ValueError) as error:
        print(f"FAIL: {type(error).__name__}: {error}")
        return 2
    finally:
        try:
            if device.connected:
                device.abort_mute()
        except DriverError:
            pass
        device.close()


if __name__ == "__main__":
    raise SystemExit(run())
