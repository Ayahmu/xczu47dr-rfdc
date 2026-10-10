#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Measure the 100G bulk upload rate, then play the record once.

板上测速：把一段随机波形经 100G 批量通路上传到 DDR4，报告端到端速率、丢帧和
补发情况，再完整播放一遍确认 DDR4 里的数据能连续读出。不需要示波器和外部触发。

Connections (先接好再跑):

    XS17 <- 250 MHz 参考时钟
    100G QSFP28 网口 -> 主机 100G 网卡
    CH1..CH8 会输出随机噪声(频谱很宽)，不想让它进后级设备就先断开

Expected result on the reference setup (MTU 1500, 4 sender threads):

    upload: 8191 MiB in 0.750 s = 91.6 Gb/s, transport=bulk, resent_chunks=0, dropped=0
    playback: state=done, underflow=0, beats=33550336/33550336

IMAGE_MIB = 8191 fills the whole DDR4 and needs about 10 GB of free host
memory; generating the random data takes far longer than sending it.  If the
rate is low, see "批量上传" in docs/API参考.md for the conditions.
Edit the constants below, then run the file without command-line arguments.
"""

from __future__ import annotations

import time

import numpy as np

from dr47 import Dr47Device, DriverError

# 连接参数(按本板/本主机实测填写)
BOARD_IP = "169.254.5.248"
BOARD_PORT = 1234
UDP_INTERFACE = "enp33s0f0np0"
UDP_SOURCE_IP = "169.254.250.11"

# 测试参数
IMAGE_MIB = 1024                  # DDR4 图像大小(MiB)，1..8191；始终按 8 个通道计
OUTPUT_CHANNELS = (1, 2, 3, 4, 5, 6, 7, 8)
AMPLITUDE_CODE = 20000            # 随机样点的峰值，int16 码值
MIN_RATE_GBPS = 0.0               # 低于该速率判 FAIL；0 = 只报告不判定

UDP_TIMEOUT_S = 2.0
UDP_RETRIES = 3
RFDC_READY_TIMEOUT_S = 30.0
PLAYBACK_TIMEOUT_S = 30.0
POLL_INTERVAL_S = 0.02
CHANNEL_MASK = sum(1 << (channel - 1) for channel in OUTPUT_CHANNELS)
DAC_BEAT_BYTES = 256              # 8 channels x 8 I/Q samples x 2 int16
DAC_BEAT_S = 20e-9


def make_waveforms() -> dict[int, np.ndarray]:
    """One interleaved I/Q int16 array per channel; together they fill IMAGE_MIB."""
    beats = (IMAGE_MIB << 20) // DAC_BEAT_BYTES
    rng = np.random.default_rng(1)
    return {
        channel: rng.integers(-AMPLITUDE_CODE, AMPLITUDE_CODE, beats * 16, dtype=np.int16)
        for channel in OUTPUT_CHANNELS
    }


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


def wait_state(device: Dr47Device, session: int, wanted: tuple[str, ...], timeout_s: float) -> dict:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        status = device.waveform_status(session=session)
        if status["state_name"] in wanted:
            return status
        if status["state_name"] == "error":
            raise RuntimeError(f"board entered error (status={status.get('status')}, "
                               f"error_code={status.get('error_code')}, "
                               f"underflow={status.get('underflow_count')})")
        time.sleep(POLL_INTERVAL_S)
    raise TimeoutError(f"board did not reach {' or '.join(wanted)}")


def run() -> int:
    print(f"[1/4] generate {IMAGE_MIB} MiB of random I/Q for channels {OUTPUT_CHANNELS}")
    waves = make_waveforms()
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
        print(f"[2/4] connect {BOARD_IP}:{BOARD_PORT}")
        device.connect()
        device.abort()
        wait_rfdc_ready(device)

        print("[3/4] upload and COMMIT")
        started = time.perf_counter()
        result = device.upload_waveforms(
            waves,
            wave_formats={channel: "interleaved_iq" for channel in waves},
            channel_mask=CHANNEL_MASK,
            loop_count=1,
        )
        elapsed = time.perf_counter() - started
        session = int(result["session"])
        rate_gbps = result["bytes"] * 8 / elapsed / 1e9
        resent = result.get("resent_chunks", [])
        dropped = int(result.get("rx_dropped_full", 0)) + int(result.get("rx_dropped_bad", 0))
        print(f"    upload: {result['bytes'] >> 20} MiB in {elapsed:.3f} s = {rate_gbps:.1f} Gb/s, "
              f"transport={result['transport']}, resent_chunks={len(resent)}, dropped={dropped}")

        print("[4/4] play the whole record once")
        wait_state(device, session, ("wait_trigger",), PLAYBACK_TIMEOUT_S)
        device.play(session=session)
        status = wait_state(device, session, ("done",),
                            PLAYBACK_TIMEOUT_S + result["total_beats"] * DAC_BEAT_S)
        print(f"    playback: state={status['state_name']}, underflow={status['underflow_count']}, "
              f"beats={status['current_beat']}/{result['total_beats']}")

        if result["transport"] != "bulk":
            print("FAIL: the upload did not use the bulk path "
                  "(bitstream without it, or the image is below 1 MiB)")
            return 1
        if status["underflow_count"]:
            print("FAIL: playback underflow")
            return 1
        if rate_gbps < MIN_RATE_GBPS:
            print(f"FAIL: {rate_gbps:.1f} Gb/s is below MIN_RATE_GBPS={MIN_RATE_GBPS}")
            return 1
        print(f"PASS: {rate_gbps:.1f} Gb/s over the bulk path, record played back completely")
        return 0
    except (DriverError, RuntimeError, TimeoutError, ValueError) as error:
        print(f"FAIL: {error}")
        return 1
    finally:
        if device.connected:
            try:
                device.abort()
            except DriverError as error:
                print(f"WARN: cleanup failed: {error}")
        device.close()


if __name__ == "__main__":
    raise SystemExit(run())
