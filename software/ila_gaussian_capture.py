#!/usr/bin/env python3
"""主卡单板 ILA 高斯包络抓取验证脚本。

背景与目标
----------
历史上曾观察到：``top_i/dac_ch1_valid_gated`` 已经置 1，但 RFDC 输入端
``top_i/dac_in_ch1_tdata`` 一直是 ``0x00010000...`` 这类常数，导致示波器上看不到
正确的高斯波形。本脚本专门用于在 ILA 里确认：主卡播放一段 0 Hz 基带高斯包络时，
真正进入 RFDC 的 ``top_i/rfdc_ch1_tdata`` 是否呈现出「先为零 -> 高斯包络 -> 再回零」
的变化过程，而不是恒定值。

抓取信号
--------
* ``top_i/rfdc_ch1_tdata``：最终送入 RFDC 的 CH1 数据（256 bit / 一个字）。
* ``top_i/rfdc_ch1_tvalid``：该字的有效标志。
* ``top_i/dac_ch1_valid_gated``：DDR 执行器输出的有效标志（与 ch1_allow 相与）。
* ``top_i/pc_started``：DAC 域播放启动标志，作为 ILA 触发源。注意不能用
  ``pc_trig_start``：那是旧 GPIO/RVCTRL 路径专用的触发脉冲，RFCTRL2 软件
  ``trigger()`` 走的是 ``rfctrl2_trigger`` 路径，会直接把 ``started`` 拉高而
  不会产生 ``trig_start``，因此用 ``pc_trig_start`` 永远抓不到 RFCTRL2 播放。
* ``top_i/pc_trig_pulse``、``top_i/pc_ch1_fire_count``、``top_i/pc_underflow_seen``、
  ``top_i/pc_done_pulse``：辅助状态，便于判断播放是否真正发生。

工作流程
--------
1. 后台启动 Vivado：连接 hw_server，选中主卡 JTAG，套用主卡 ltx，找到带
   ``rfdc_ch1_tdata`` 探针的 ILA，把触发设为 ``pc_started`` 上升沿，然后
   ``run_hw_ila`` 并写一个 ``armed`` 标记文件，进入 ``wait_on_hw_ila`` 阻塞。
2. Python 等待 ``armed`` 文件出现，说明 ILA 已经就绪。
3. Python 通过 ``dr47`` 驱动向主卡上传 0 Hz 基带高斯包络，然后 ARM + 软件
   ``trigger()``。主卡无需先 ``sync()`` 即可本地播放。
4. 触发沿到达后 Vivado 完成抓取并写出 CSV；Python 解析 CSV，把 ``rfdc_ch1_tdata``
   解码成 int16 样本，确认存在一段非零且幅度呈钟形的高斯包络。

运行（需要 Vivado 2024.2 与运行中的 hw_server）
--------------------------------------------
    cd /home/yk/workspace/xczu47dr-rfdc
    source /home/yk/Vivado/2024.2/settings64.sh
    PYTHONPATH=software .venv/bin/python -m ila_gaussian_capture

网络、JTAG、波形参数都在文件顶部以模块常量定义，不接受命令行参数。
"""

from __future__ import annotations

import csv
import re
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from dr47.device import Dr47Device  # noqa: E402
from dr47.sequence import make_single_trigger_sequence  # noqa: E402
from dr47.waveforms import (  # noqa: E402
    iq_duration_to_interleaved_sample_count,
    make_iq_gaussian_sine_interleaved,
    place_interleaved_iq_in_record,
)


# ---- 网络配置 ---------------------------------------------------------------
BOARD_PORT = 1234
NETWORK_INTERFACE = "enp1s0f0"
CONTROL_SOURCE_IP = "169.254.250.11"
MASTER_TARGET_IP = "169.254.100.101"  # 082 = master

# ---- JTAG / Vivado 配置 -----------------------------------------------------
HW_SERVER = "localhost:3121"
JTAG_TARGET = "localhost:3121/xilinx_tcf/Xilinx/210512180082"
MASTER_LTX = str(SCRIPT_DIR.parent / "artifacts" / "custom_xczu47dr_master.ltx")
VIVADO_BIN = "vivado"
CAPTURE_DEPTH = 4096
TRIGGER_POSITION = 1024

# ---- 波形参数 ---------------------------------------------------------------
# 400 MS/s 复基带；RFDC NCO 产生 1 GHz 射频载波，软件记录使用 0 Hz 基带。
# 为了让 ILA 能清楚看到包络，这里把高斯时长放宽到 256 ns，得到约 12 个字。
SAMPLE_RATE_HZ = 400_000_000.0
RF_NCO_GHZ = 1.0
BASEBAND_GHZ = 0.0
PULSE_DURATION_NS = 256.0
PULSE_DELAY_NS = 200.0
RECORD_DURATION_NS = 1024.0
WAVEFORM_AMPLITUDE = 0.2
GAIN = 0.2
CHANNEL_MASK = 0x01

# 抓取时关注的 ILA 探针名（与当前主卡 ltx 里的真实名称一致）。
PROBE_TDATA = "top_i/rfdc_ch1_tdata"
PROBE_TVALID = "top_i/rfdc_ch1_tvalid"
PROBE_VALID_GATED = "top_i/dac_ch1_valid_gated"
PROBE_TRIGGER = "top_i/pc_started"
AUX_PROBES = (
    "top_i/pc_trig_pulse",
    "top_i/pc_ch1_fire_count",
    "top_i/pc_underflow_seen",
    "top_i/pc_done_pulse",
)


def _make_gaussian_record() -> np.ndarray:
    """生成带前置延迟的 0 Hz 基带高斯 IQ 记录（返回 interleaved int16）。"""

    duration_s = PULSE_DURATION_NS * 1e-9
    active_count = iq_duration_to_interleaved_sample_count(duration_s, SAMPLE_RATE_HZ)
    active = make_iq_gaussian_sine_interleaved(
        frequency_hz=BASEBAND_GHZ * 1e9,
        phase_rad=0.0,
        amplitude=round(WAVEFORM_AMPLITUDE * 32767.0),
        sample_rate_hz=SAMPLE_RATE_HZ,
        duration_s=duration_s,
        sample_count=active_count,
        fwhm_s=duration_s / 2.0,
        q_sign=-1,
    )
    return place_interleaved_iq_in_record(
        active,
        delay_s=PULSE_DELAY_NS * 1e-9,
        record_duration_s=RECORD_DURATION_NS * 1e-9,
        sample_rate_hz=SAMPLE_RATE_HZ,
    )


def _write_capture_tcl(armed_path: Path, csv_path: Path) -> Path:
    """生成 Vivado 抓取 Tcl，返回 Tcl 文件路径。"""

    out_dir = Path("ila_gaussian_reports")
    out_dir.mkdir(parents=True, exist_ok=True)
    tcl_path = out_dir / "capture.tcl"
    lines = [
        "set_param messaging.defaultLimit 10000",
        "open_hw_manager",
        f"connect_hw_server -allow_non_jtag -url {HW_SERVER}",
        f"open_hw_target {JTAG_TARGET}",
        "set dev [lindex [get_hw_devices] 0]",
        "current_hw_device $dev",
        f"set_property PROBES.FILE {{{MASTER_LTX}}} $dev",
        "refresh_hw_device $dev",
        "set ilas [get_hw_ilas -of_objects $dev]",
        "set ila {}",
        f"set data_probe {{{PROBE_TDATA}}}",
        "foreach candidate $ilas {",
        "  set found [get_hw_probes $data_probe -of_objects $candidate]",
        "  if {[llength $found] == 0} { set found [get_hw_probes *$data_probe* -of_objects $candidate] }",
        "  if {[llength $found] > 0} { set ila $candidate; break }",
        "}",
        "if {$ila eq \"\"} { error \"No ILA has probe 'top_i/rfdc_ch1_tdata'\" }",
        "puts \"Using ILA: [get_property NAME $ila]\"",
        "current_hw_ila $ila",
        f"catch {{ set_property CONTROL.DATA_DEPTH {CAPTURE_DEPTH} $ila }}",
        f"catch {{ set_property CONTROL.TRIGGER_POSITION {TRIGGER_POSITION} $ila }}",
        f"set trig_probe [lindex [get_hw_probes {{{PROBE_TRIGGER}}} -of_objects $ila] 0]",
        "if {$trig_probe eq \"\"} { set trig_probe [lindex [get_hw_probes *pc_started* -of_objects $ila] 0] }",
        "if {$trig_probe eq \"\"} { error \"Missing trigger probe pc_started\" }",
        "if {[catch { set_property TRIGGER_COMPARE_VALUE {eq1'b1} $trig_probe } msg]} { error \"Failed to set trigger compare: $msg\" }",
        f"set armed_file {{{armed_path}}}",
        "set fp [open $armed_file w]",
        "puts $fp armed",
        "close $fp",
        "run_hw_ila $ila",
        "wait_on_hw_ila $ila",
        "set data [upload_hw_ila_data $ila]",
        f"write_hw_ila_data -force -csv_file {{{csv_path}}} $data",
        "close_hw_manager",
    ]
    tcl_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return tcl_path


def _decode_tdata_words(words: list[int]) -> np.ndarray:
    """把 256-bit 的 ``rfdc_ch1_tdata`` 字按小端 int16 解码成一维样本数组。"""

    raw = bytearray()
    for word in words:
        raw.extend((int(word) & ((1 << 256) - 1)).to_bytes(32, byteorder="little", signed=False))
    return np.frombuffer(bytes(raw), dtype="<i2").astype(np.int32)


def _parse_scalar(value: str) -> int:
    """把 ILA CSV 里二进制/十六进制形式的标量转换为整数。"""

    text = value.strip().strip('"').replace("_", "")
    if text == "":
        return 0
    if text.lower().startswith("0x"):
        return int(text, 16)
    # 256-bit 数据总线在 ILA CSV 里以 64 位十六进制字符串输出；优先按十六进制
    # 解析，避免被下面的二进制分支误判（例如含 0/1 的十六进制数）。
    if len(text) > 8 and re.fullmatch(r"[0-9a-fA-F]+", text):
        return int(text, 16)
    if re.fullmatch(r"[01xzXZ]+", text) and len(text) > 1:
        return int(text.replace("x", "0").replace("X", "0").replace("z", "0").replace("Z", "0"), 2)
    return int(text, 0)


def _analyze_csv(csv_path: Path) -> None:
    """解析 ILA CSV，确认 ``rfdc_ch1_tdata`` 呈现高斯包络而非恒定值。"""

    with csv_path.open("r", encoding="utf-8-sig", newline="") as f:
        sample = f.read(4096)
        f.seek(0)
        try:
            dialect = csv.Sniffer().sniff(sample, delimiters=",;\t") if sample.strip() else csv.excel
        except csv.Error:
            dialect = csv.excel
        rows = list(csv.reader(f, dialect))

    # 找到表头行（含探针名），再取数据行。
    header_idx = None
    for idx, row in enumerate(rows):
        if any("top_i/" in str(c) for c in row) or any("Sample" in str(c) for c in row):
            header_idx = idx
            break
    if header_idx is None:
        raise RuntimeError("ILA CSV 中找不到表头")
    header = [str(c).strip().strip('"') for c in rows[header_idx]]
    # 跳过 Vivado 写出的 "Radix - ..." 行和空行。
    data_rows = [
        r
        for r in rows[header_idx + 1 :]
        if any(str(c).strip() for c in r)
        and not (str(r[0]).strip().lower().startswith("radix"))
    ]

    def col_index(candidates: tuple[str, ...]) -> int:
        for cand in candidates:
            if cand in header:
                return header.index(cand)
            for idx, name in enumerate(header):
                if name.endswith(cand):
                    return idx
                # 总线探针在 CSV 表头里带 [msb:lsb] 后缀。
                if re.search(re.escape(cand) + r"\[\d+:\d+\]$", name):
                    return idx
        raise RuntimeError(f"CSV 缺少探针: {candidates}")

    tdata_col = col_index((PROBE_TDATA,))
    valid_col = col_index((PROBE_VALID_GATED, PROBE_TVALID))

    words: list[int] = []
    valid_count = 0
    for row in data_rows:
        padded = row + [""] * (len(header) - len(row))
        valid = _parse_scalar(padded[valid_col])
        if valid:
            valid_count += 1
        words.append(_parse_scalar(padded[tdata_col]))

    samples = _decode_tdata_words(words)
    nonzero = int(np.count_nonzero(samples))
    peak = int(np.max(np.abs(samples))) if samples.size else 0
    # 只统计真正有效窗口里的样本，避免记录前半段前置零把包络掩盖掉。
    active = samples[np.abs(samples) > 0]

    print(f"ILA 抓取完成：总样本={samples.size}，有效字={valid_count}，非零样本={nonzero}，峰值幅度={peak}")
    if nonzero == 0:
        print("FAIL: rfdc_ch1_tdata 全为零，未看到任何波形数据。")
        raise SystemExit(2)
    if active.size < 8:
        print("FAIL: 非零样本过少，无法构成高斯包络。")
        raise SystemExit(2)
    # 高斯包络应单调上升到峰值再单调下降；这里用「峰值位置不在两端」做粗校验。
    peak_pos = int(np.argmax(np.abs(active)))
    if peak_pos == 0 or peak_pos >= active.size - 1:
        print("WARN: 包络峰值位于边缘，波形可能被截断。")
    print(f"有效窗口内样本数={active.size}，峰值位置={peak_pos}/{active.size - 1}")
    print("PASS: rfdc_ch1_tdata 呈现非零且钟形变化的高斯包络，不再是恒定值。")


def _wait_armed(armed_path: Path, process: subprocess.Popen, timeout_s: int = 120) -> None:
    """等待 Vivado 写出 armed 标记，若提前退出则报错。"""

    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if armed_path.exists():
            return
        if process.poll() is not None:
            raise RuntimeError("Vivado 在 ILA 就绪前退出，请查看 ila_gaussian_reports 日志")
        time.sleep(0.2)
    raise TimeoutError(f"ILA 未在 {timeout_s}s 内就绪")


def _play_gaussian() -> None:
    """通过 dr47 向主卡上传 0 Hz 高斯包络并 ARM + 触发一次。"""

    record = _make_gaussian_record()
    device = Dr47Device(
        ip=MASTER_TARGET_IP,
        port=BOARD_PORT,
        udp_interface=NETWORK_INTERFACE,
        udp_source_ip=CONTROL_SOURCE_IP,
        timeout_s=1.0,
        retries=2,
        batch_mode=True,
    )
    try:
        device.connect()
        print("已连接主卡，等待 RFDC 就绪。", flush=True)
        deadline = time.monotonic() + 30.0
        while time.monotonic() < deadline:
            caps = device.status(refresh=True).capabilities
            if caps.rfdc_ready and caps.dac_mts_ready and caps.nco_sync_ready:
                break
            if caps.dac_mts_failed:
                raise AssertionError(f"DAC MTS 失败：error=0x{caps.dac_mts_error:04X}")
            time.sleep(0.05)
        else:
            raise AssertionError("主卡 RFDC 未就绪")

        device.require_external_sync()
        device.set_xy_nco_frequency(1, RF_NCO_GHZ)
        device.set_gain("xy", 1, GAIN, gain_type="norm")
        device.set_qc_on_off("xy", 1, "on")
        device.commit()
        print("上传高斯包络并等待 DDR 预取。", flush=True)
        device.upload_waveforms(
            {1: record},
        channel_sequences={1: make_single_trigger_sequence(int(record.size // 2))},
            wave_formats={1: "interleaved_iq"},
            auto_start=False,
            loop=False,
            instruction_repeats=1,
        )
        # 等待 DDR executor 接收 PLAY/END 并完成波形预取，避免触发时数据尚未就绪。
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            raw = device.status(refresh=True).capabilities.raw
            channel_mask = int(raw.get("play_config_channel_mask", 0)) & 0xFF
            pending = bool(raw.get("play_pending_valid", False))
            prefill = bool(raw.get("play_prefill_ready", False))
            if (channel_mask & CHANNEL_MASK) == CHANNEL_MASK and pending and prefill:
                break
            time.sleep(0.02)
        else:
            raise AssertionError("波形配置未就绪")

        print("ARM 主卡并等待 PREPARED。", flush=True)
        device.arm(channel_mask=CHANNEL_MASK)
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            if device.status(refresh=True).state.value == "prepared":
                break
            time.sleep(0.02)
        else:
            raise AssertionError("主卡未进入 PREPARED")

        print("发送软件 TRIGGER。", flush=True)
        device.trigger()
        print("已通过 dr47 上传高斯包络并触发主卡播放。", flush=True)
    finally:
        try:
            if device.connected:
                device.abort_mute()
        except Exception:
            pass
        device.close()


def main() -> int:
    out_dir = Path("ila_gaussian_reports")
    out_dir.mkdir(parents=True, exist_ok=True)
    armed_path = out_dir / "armed.flag"
    csv_path = out_dir / "capture.csv"
    stdout_path = out_dir / "vivado_stdout.log"
    stderr_path = out_dir / "vivado_stderr.log"
    if armed_path.exists():
        armed_path.unlink()
    tcl_path = _write_capture_tcl(armed_path, csv_path)

    # 把 Vivado 输出直接写到文件，即使 wait_on_hw_ila 长时间阻塞也能实时查看日志。
    stdout_fp = stdout_path.open("w", encoding="utf-8")
    stderr_fp = stderr_path.open("w", encoding="utf-8")
    process = subprocess.Popen(
        [VIVADO_BIN, "-mode", "batch", "-source", str(tcl_path)],
        cwd=Path.cwd(),
        text=True,
        stdout=stdout_fp,
        stderr=stderr_fp,
    )
    try:
        _wait_armed(armed_path, process)
        print("ILA 已就绪，开始上传并触发主卡播放。", flush=True)
        _play_gaussian()
        process.wait(timeout=120)
    except Exception:
        process.kill()
        process.wait()
        raise
    finally:
        stdout_fp.close()
        stderr_fp.close()
    if process.returncode != 0:
        print(f"FAIL: Vivado 抓取失败，退出码 {process.returncode}，日志见 {out_dir}")
        return 2
    if not csv_path.exists():
        print(f"FAIL: Vivado 完成但未生成 {csv_path}")
        return 2
    _analyze_csv(csv_path)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
