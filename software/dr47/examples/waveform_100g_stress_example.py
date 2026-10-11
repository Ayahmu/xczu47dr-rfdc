#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Stress the 100G link: sustained bulk traffic, measured bandwidth and frame loss.

100G 压测：按若干档发送线程数，持续向板卡的批量通路灌数据，每档报告实测带宽和
丢包率，并按环节给出丢包位置。数据经过和正式上传完全相同的路径（网卡 -> QSFP28 ->
CMAC -> 512 bit 帧 FIFO -> DDR4 写入），但不补发、不 COMMIT、不播放，所以统计的是
一次发送的原始丢包。不需要示波器和外部触发，RF 口没有输出。

Connections (先接好再跑):

    100G QSFP28 网口 -> 主机 100G 网卡

每一档在同一个会话里把 IMAGE_MIB 的图像一遍接一遍地发满 STEP_DURATION_S，两遍之间
只隔一次计数器查询(约 0.1 ms)。板端每收到一帧都会写入 DDR4 并计数：

    sent        主机交给内核的数据报数
    on_wire     网卡实际发出的帧数 (ethtool tx_packets_phy；读不到时显示 n/a)
    tx_queues   这一档里承担过流量的网卡发送队列数 (读不到时显示 n/a)
    board_rx    板端分类器看到的批量帧数
    bad_fcs     CMAC 标记为坏帧而丢弃的帧数
    fifo_full   板端帧 FIFO 满而丢弃的帧数 (DDR4 写入跟不上)
    rejected    DDR 写入器拒收的帧数 (会话/偏移/长度不合法)
    stored      完整写入 DDR4 的帧数
    loss        (sent - stored) / sent

带宽有两个口径：goodput 只算波形数据；wire 把以太网/IP/UDP/批量头、FCS、前导码和
帧间隔都算上，是链路上真正占用的速率，上限 100 Gb/s。标准 MTU 下一帧带 1024 字节
数据、占线路 1112 字节，所以 goodput 上限约 92.1 Gb/s。

怎么读结果：board_rx 等于 sent 且 bad_fcs 为 0，说明链路本身没有丢帧。fifo_full 不为 0
而 tx_queues 大于 1 时，丢帧来自主机：网卡按 CPU 分发送队列(XPS)时，内核大约每秒为
socket 重选一次队列，切换的瞬间两个队列的帧交错到达，板卡每写一帧都要换 DDR4 行，
写入暂时跟不上。正式上传靠分块补发覆盖这种丢帧；要在压测里消除它，需要 root 权限让
发送线程固定在同一个发送队列上(例如 ethtool -L <网卡> combined 1；参考主机没有 root，未实测)。

Expected result on the reference setup (MTU 1500, XPS with one queue per CPU, 20 s per step):

    threads=1: goodput 49 Gb/s, wire 53 Gb/s,   loss 0
    threads=2: goodput 84 Gb/s, wire 91 Gb/s,   loss 0 .. 1e-5, all of it fifo_full
    threads=4: goodput 92 Gb/s, wire 99.7 Gb/s, loss 3e-6 .. 4e-5, all of it fifo_full

Edit the constants below, then run the file without command-line arguments.
"""

from __future__ import annotations

import re
import subprocess
import time

import numpy as np

from dr47 import Dr47Device, DriverError
from dr47.bulk import BulkSender, payload_bytes_for_interface
from dr47.protocol import (
    WAVE_BULK_HEADER_BYTES,
    WAVE_BULK_PORT_OFFSET,
    WAVE_LAYOUT_INTERLEAVED_512B_BULK,
)

# 连接参数(按本板/本主机实测填写)
BOARD_IP = "169.254.5.248"
BOARD_PORT = 1234
UDP_INTERFACE = "enp33s0f0np0"
UDP_SOURCE_IP = "169.254.250.11"

# 测试参数
IMAGE_MIB = 1024                  # 反复发送的图像大小(MiB)，1..8191；占用同样多的主机内存
STEP_DURATION_S = 20.0            # 每一档持续发送的时间(s)；发完当前这一遍才停
SENDER_THREADS = (1, 2, 4)        # 依次测试的发送线程数；线程越多，主机给出的负载越大
MAX_LINK_LOSS_RATE = 0.0          # 任一档链路丢帧率 (没到板卡的帧 + 坏帧) 高于该值判 FAIL
MAX_LOSS_RATE = 1e-3              # 任一档总丢包率高于该值判 FAIL；线速档的预期值见上面的说明
MIN_WIRE_RATE_GBPS = 0.0          # 最高一档的线路速率低于该值判 FAIL；0 = 只报告不判定

UDP_TIMEOUT_S = 2.0
UDP_RETRIES = 3
SETTLE_POLL_S = 0.02              # 发完一遍后轮询板端计数器的间隔
DAC_BEAT_BYTES = 256              # 8 channels x 8 I/Q samples x 2 int16
# 一帧在线路上除数据以外占用的字节：批量头 + UDP + IPv4 + 以太网头 + FCS + 前导码 + 帧间隔
FRAME_OVERHEAD_BYTES = WAVE_BULK_HEADER_BYTES + 8 + 20 + 14 + 4 + 8 + 12
# 板端计数器都是 32 位；每发完一遍采样一次并按模 2**32 累加，线速下也不会回绕丢数。
COUNTER_KEYS = ("bulk_rx_frames", "bulk_rx_dropped_bad", "bulk_rx_dropped_full",
                "bulk_frames_ok", "bulk_frames_duplicate", "bulk_frames_stale", "bulk_frames_rejected")


def make_image() -> np.ndarray:
    """IMAGE_MIB of a counting pattern; the content does not affect the result."""
    return np.arange((IMAGE_MIB << 20) // 8, dtype="<u8").view(np.uint8)


def nic_tx_counters() -> dict[str, int]:
    """The card's transmit counters: "phy" (frames on the wire) and one per queue.

    Empty when ethtool is missing; a counter the driver does not report is absent.
    """
    try:
        text = subprocess.run(["ethtool", "-S", UDP_INTERFACE], capture_output=True, text=True,
                              timeout=5, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    counters = {}
    for line in text.splitlines():
        name, _, value = line.partition(":")
        name = name.strip()
        if name == "tx_packets_phy":
            counters["phy"] = int(value)
        elif (queue := re.fullmatch(r"tx_?(?:queue_)?(\d+)_packets", name)):
            counters[queue.group(1)] = int(value)
    return counters


def bulk_counters(device: Dr47Device, session: int) -> dict:
    status = device.bulk_status(session=session)
    if int(status["status"]) != 0:
        raise RuntimeError(f"BULK_STATUS failed with status {status['status']}")
    if status["bulk_axi_error"]:
        raise RuntimeError("DDR write error during the stress run")
    return status


def settled_counters(device: Dr47Device, session: int) -> dict:
    """Bulk counters once two polls in a row see no new frame."""
    previous, stable = None, 0
    while True:
        status = bulk_counters(device, session)
        stable = stable + 1 if status["bulk_rx_frames"] == previous else 0
        if stable >= 2:
            return status
        previous = status["bulk_rx_frames"]
        time.sleep(SETTLE_POLL_S)


def run_step(device: Dr47Device, image: np.ndarray, threads: int, payload_bytes: int,
             session: int) -> dict:
    """One load step: the image over and over for STEP_DURATION_S in one session."""
    begun = device.begin_waveform(
        session=session, total_bytes=image.size, channel_mask=0xFF,
        total_beats=image.size // DAC_BEAT_BYTES, loop_count=1,
        layout=WAVE_LAYOUT_INTERLEAVED_512B_BULK)
    if int(begun["status"]) != 0:
        raise RuntimeError(f"BEGIN failed with status {begun['status']} "
                           "(bitstream without the bulk path?)")
    sender = BulkSender(BOARD_IP, BOARD_PORT + WAVE_BULK_PORT_OFFSET, udp_interface=UDP_INTERFACE,
                        udp_source_ip=UDP_SOURCE_IP, threads=threads, accelerate=True)
    total = dict.fromkeys(COUNTER_KEYS, 0)
    total.update(sent=0, passes=0)

    def accumulate(sample: dict, last: dict) -> dict:
        for key in COUNTER_KEYS:
            total[key] += (int(sample[key]) - int(last[key])) & 0xFFFF_FFFF
        return sample

    try:
        last = settled_counters(device, session)      # answered once the session is armed
        nic_before = nic_tx_counters()
        started = time.perf_counter()
        while not total["passes"] or time.perf_counter() - started < STEP_DURATION_S:
            # The board writes every frame it receives; frames of a repeated
            # pass are counted as duplicates of an already complete chunk.
            total["sent"] += sender.send(image, 0, image.size, session=session, epoch=0,
                                         payload_bytes=payload_bytes)
            total["passes"] += 1
            last = accumulate(bulk_counters(device, session), last)
        total["elapsed"] = time.perf_counter() - started
        accumulate(settled_counters(device, session), last)
        nic_after = nic_tx_counters()
    finally:
        sender.close()
        device.abort()
    moved = {key: nic_after[key] - value for key, value in nic_before.items() if key in nic_after}
    total["wire"] = moved.pop("phy", None)
    # A queue counts once it carried more than a stray control packet or two.
    total["queues"] = sum(1 for frames in moved.values() if frames > total["sent"] // 1000) if moved else None
    total["stored"] = total["bulk_frames_ok"] + total["bulk_frames_duplicate"] + total["bulk_frames_stale"]
    return total


def report(threads: int, total: dict, payload_bytes: int) -> tuple[float, float, float]:
    """Print one step; returns its link loss rate, total loss rate and wire rate in Gb/s."""
    sent, elapsed = total["sent"], total["elapsed"]
    goodput = sent * payload_bytes * 8 / elapsed / 1e9
    wire_rate = sent * (payload_bytes + FRAME_OVERHEAD_BYTES) * 8 / elapsed / 1e9
    loss = (sent - total["stored"]) / sent
    link_loss = (max(sent - total["bulk_rx_frames"], 0) + total["bulk_rx_dropped_bad"]) / sent
    on_wire = "n/a" if total["wire"] is None else str(total["wire"])
    queues = "n/a" if total["queues"] is None else str(total["queues"])
    print(f"    threads={threads}: {total['passes']} passes, {sent * payload_bytes / 2**30:.1f} GiB in "
          f"{elapsed:.2f} s = goodput {goodput:.1f} Gb/s, wire {wire_rate:.1f} Gb/s")
    print(f"        sent={sent} on_wire={on_wire} tx_queues={queues} board_rx={total['bulk_rx_frames']} "
          f"bad_fcs={total['bulk_rx_dropped_bad']} fifo_full={total['bulk_rx_dropped_full']} "
          f"rejected={total['bulk_frames_rejected']} stored={total['stored']} "
          f"loss={sent - total['stored']} ({loss:.3e})")
    return link_loss, loss, wire_rate


def run() -> int:
    print(f"[1/3] build a {IMAGE_MIB} MiB image")
    image = make_image()
    payload_bytes = payload_bytes_for_interface(UDP_INTERFACE)
    device = Dr47Device(
        ip=BOARD_IP,
        port=BOARD_PORT,
        udp_interface=UDP_INTERFACE,
        udp_source_ip=UDP_SOURCE_IP,
        timeout_s=UDP_TIMEOUT_S,
        retries=UDP_RETRIES,
        batch_mode=True,
    )
    try:
        print(f"[2/3] connect {BOARD_IP}:{BOARD_PORT}")
        device.connect()
        device.abort()

        print(f"[3/3] send {payload_bytes}-byte datagrams for {STEP_DURATION_S:g} s per step")
        worst_link_loss, worst_loss, wire_rate = 0.0, 0.0, 0.0
        for session, threads in enumerate(SENDER_THREADS, start=1):
            total = run_step(device, image, threads, payload_bytes, session)
            link_loss, loss, wire_rate = report(threads, total, payload_bytes)
            worst_link_loss = max(worst_link_loss, link_loss)
            worst_loss = max(worst_loss, loss)

        if worst_link_loss > MAX_LINK_LOSS_RATE:
            print(f"FAIL: link loss rate {worst_link_loss:.3e} is above MAX_LINK_LOSS_RATE={MAX_LINK_LOSS_RATE:g}")
            return 1
        if worst_loss > MAX_LOSS_RATE:
            print(f"FAIL: loss rate {worst_loss:.3e} is above MAX_LOSS_RATE={MAX_LOSS_RATE:g}")
            return 1
        if wire_rate < MIN_WIRE_RATE_GBPS:
            print(f"FAIL: {wire_rate:.1f} Gb/s on the wire is below MIN_WIRE_RATE_GBPS={MIN_WIRE_RATE_GBPS}")
            return 1
        print(f"PASS: up to {wire_rate:.1f} Gb/s on the wire, link loss rate {worst_link_loss:.3e}, "
              f"worst total loss rate {worst_loss:.3e}")
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
