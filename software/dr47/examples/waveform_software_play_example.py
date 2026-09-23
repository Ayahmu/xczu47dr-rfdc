#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Upload one WAVECTR0 record and start it with the board-local PLAY command.

在 CH1/CH2 输出一包"高斯正弦脉冲"供示波器观察,走"软件 PLAY"路径——不需要
外部触发线,运行脚本即发波。

Connections (先接好再跑):

    XS17 <- 250 MHz 参考时钟 (必须接,否则频率全错)
    CH1  -> 示波器通道 1 (50 Ω 端接),板子丝印 vout00
    CH2  -> 示波器通道 2 (50 Ω 端接),板子丝印 vout02
    10G 网口 -> 主机
    XS19 (外部触发) 本脚本用不到,可断开

示波器配合:

    - 关键:示波器带宽必须 >= RF_FREQUENCY_GHZ,否则看不到信号。
      建议第一次先用 0.5 GHz 或更低。
    - 触发:单次 Single + 上升沿 + 触发电平靠近 0 V + 最大预触发;
      先按示波器 Run,再运行本脚本。
    - 时基 50 ns/格,垂直 20 mV/格起,再逐档放大。
    - 看到的结果:一包正弦(中间密、两头稀的高斯包络),前后都是零电平。

This sample exercises the single-board waveform contract only. It does not
select a master/slave role, configure XS20 bypass, or emit a legacy trigger.
Edit the constants below, then run the file without command-line arguments.
"""

from __future__ import annotations

import time

from dr47 import Dr47Device, DriverError, PlaybackState, make_iq_gaussian_sine_interleaved

# 连接参数(按本板/本主机实测填写)
BOARD_IP = "169.254.5.248"
BOARD_PORT = 1234
UDP_INTERFACE = "enp1s0f1"
UDP_SOURCE_IP = "169.254.250.11"

# 波形/DAC 参数
OUTPUT_CHANNELS = (1, 2)
RF_FREQUENCY_GHZ = 0.500          # 输出 RF 中心频率(GHz),设到示波器带宽内!
BASEBAND_HZ = 0.0                 # 基带载波(Hz):0 = 纯高斯包络;非 0 = 包络内塞正弦
OUTPUT_GAIN = 0.10                # 输出强度 0~1,越大越强
SAMPLE_RATE_HZ = 400_000_000.0    # IQ 采样率 400 MS/s,固定
GAUSSIAN_DURATION_NS = 100.0      # 这一包脉冲总时长(ns)
GAUSSIAN_FWHM_NS = 40.0           # 高斯包络半高全宽(ns),越小越"瘦"
GAUSSIAN_AMPLITUDE = 3_276        # 满幅 ~32768,留余量防削顶

UDP_TIMEOUT_S = 2.0
UDP_RETRIES = 3
RFDC_READY_TIMEOUT_S = 30.0
PLAYBACK_TIMEOUT_S = 10.0
POLL_INTERVAL_S = 0.02
CHANNEL_MASK = sum(1 << (channel - 1) for channel in OUTPUT_CHANNELS)


def print_upload_progress(sent_packets: int, total_packets: int) -> None:
    if total_packets <= 0:
        return
    percent = min(100, round(sent_packets * 100 / total_packets))
    print(
        f"\r    upload {percent:3d}% ({sent_packets}/{total_packets} waveform packets)",
        end="\n" if sent_packets >= total_packets else "",
        flush=True,
    )


def wait_rfdc_ready(device: Dr47Device) -> None:
    deadline = time.monotonic() + RFDC_READY_TIMEOUT_S
    while time.monotonic() < deadline:
        caps = device.status(refresh=True).capabilities
        if caps.dac_mts_failed:
            raise RuntimeError(f"DAC MTS failed: 0x{caps.dac_mts_error:04X}")
        if caps.rfdc_ready and caps.dac_mts_ready and caps.nco_sync_ready:
            return
        time.sleep(POLL_INTERVAL_S)
    raise TimeoutError("RFDC/DAC MTS/NCO did not become ready")


def wait_state(device: Dr47Device, expected: PlaybackState, label: str) -> None:
    deadline = time.monotonic() + PLAYBACK_TIMEOUT_S
    while time.monotonic() < deadline:
        actual = device.status(refresh=True).state
        if actual is expected:
            return
        time.sleep(POLL_INTERVAL_S)
    raise TimeoutError(f"{label}: expected {expected.value}")


def make_waveform():
    # 高斯包络 × 正弦载波。BASEBAND_HZ=0 时是纯高斯包络;非 0 时包络内
    # 叠加该频率的载波(最终上变频到 RF_FREQUENCY_GHZ)。
    return make_iq_gaussian_sine_interleaved(
        frequency_hz=BASEBAND_HZ,
        phase_rad=0.0,
        amplitude=GAUSSIAN_AMPLITUDE,
        sample_rate_hz=SAMPLE_RATE_HZ,
        duration_s=GAUSSIAN_DURATION_NS * 1e-9,
        fwhm_s=GAUSSIAN_FWHM_NS * 1e-9,
    )


def run() -> int:
    waveform = make_waveform()
    device = Dr47Device(
        ip=BOARD_IP,
        port=BOARD_PORT,
        udp_interface=UDP_INTERFACE,
        udp_source_ip=UDP_SOURCE_IP,
        timeout_s=UDP_TIMEOUT_S,
        retries=UDP_RETRIES,
        batch_mode=True,
    )
    session = 0
    try:
        print(f"[1/4] connect {BOARD_IP}:{BOARD_PORT}")
        device.connect()
        device.abort()
        wait_rfdc_ready(device)

        print(f"[2/4] configure channels {OUTPUT_CHANNELS} @ {RF_FREQUENCY_GHZ} GHz")
        for channel in OUTPUT_CHANNELS:
            device.set_xy_target_frequency(channel, RF_FREQUENCY_GHZ)
            device.set_gain("xy", channel, OUTPUT_GAIN)
            device.set_qc_on_off("xy", channel, "on")
        device.commit()

        print("[3/4] upload one WAVECTR0 record and COMMIT")
        result = device.upload_waveforms(
            {channel: waveform for channel in OUTPUT_CHANNELS},
            wave_formats={channel: "interleaved_iq" for channel in OUTPUT_CHANNELS},
            channel_mask=CHANNEL_MASK,
            loop_count=1,
            progress_callback=print_upload_progress,
        )
        session = int(result["session"])
        print(f"    session={session}, descriptor generation={result.get('descriptor')}")

        print("[4/4] send one software PLAY (observe the scope now)")
        device.play(session=session)
        wait_state(device, PlaybackState.PLAYING, "software PLAY")
        print(f"PASS: WAVECTR0 software PLAY admitted for session={session}")
        return 0
    except (DriverError, RuntimeError, TimeoutError, ValueError) as error:
        print(f"FAIL: {error}")
        return 1
    finally:
        if device.connected:
            try:
                device.stop(session=session)
            except DriverError as error:
                print(f"WARN: cleanup failed: {error}")
        device.close()


if __name__ == "__main__":
    raise SystemExit(run())
