#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Stress the 100G link: sustained line-rate bulk traffic, measured bandwidth and frame loss.

100G 压测：用几个发送线程把链路打满，持续向板卡的批量通路灌数据，报告实测带宽和
丢包率，并按环节给出丢包位置。数据经过和正式上传完全相同的路径（网卡 -> QSFP28 ->
CMAC -> 512 bit 帧 FIFO -> DDR4 写入），但不补发、不 COMMIT、不播放，所以统计的是
一次发送的原始丢包。不需要示波器和外部触发，RF 口没有输出。

Connections (先接好再跑):

    100G QSFP28 网口 -> 主机 100G 网卡

压测要反映的是硬件，所以主机这一侧不能成为干扰或瓶颈。脚本为此做两件事：

  * 让帧按地址顺序到达。Linux 会给 socket 更换网卡发送队列(net.core.txq_reselection_ms，
    默认每 1000 ms 强制重选一次)。更换时 socket 里如果还积压着帧，新旧两个队列的帧就
    交错着到达，板卡每写一帧都要换 DDR4 行，写入跟不上而丢帧。这种丢帧是主机造成的，
    不是链路或板卡丢的。脚本把 socket 发送缓冲限制在 SEND_BUFFER_BYTES，一遍最多发
    1 GiB(约 0.09 s)，每一遍开始前都等 socket 排空：更换队列时没有积压，或者积压少到
    板端 FIFO 能吸收。
  * 确认链路被打满。线路速率低于 MIN_WIRE_RATE_GBPS 说明瓶颈在主机(发送线程不够，或
    net.core.wmem_max 小于 SEND_BUFFER_BYTES)，结果不代表硬件的上限，判 FAIL。

每发完一遍查一次板端计数器(约 0.1 ms)。板端每收到一帧都会写入 DDR4 并计数：

    sent        主机交给内核的数据报数
    on_wire     网卡实际发出的帧数 (ethtool tx_packets_phy；读不到时显示 n/a)。控制报文也
                算在内，所以比 sent 多出几百帧是正常的；比 sent 少说明主机自己丢了帧，判 FAIL
    board_rx    板端分类器看到的批量帧数；比 sent 少的部分没有到达板卡
    bad_fcs     CMAC 标记为坏帧而丢弃的帧数
    fifo_full   板端帧 FIFO 满而丢弃的帧数 (DDR4 写入跟不上)
    rejected    DDR 写入器拒收的帧数 (会话/偏移/长度不合法)
    stored      完整写入 DDR4 的帧数
    loss        (sent - stored) / sent，高于 MAX_LOSS_RATE(默认 0，即一帧都不能丢)判 FAIL

带宽有两个口径：goodput 只算波形数据；wire 把以太网/IP/UDP/批量头、FCS、前导码和
帧间隔都算上，是链路上真正占用的速率，上限 100 Gb/s。标准 MTU 下一帧带 1024 字节
数据、占线路 1112 字节，所以 goodput 上限约 92.1 Gb/s。一遍 1 GiB 在线速下要 93.3 ms，
加上两遍之间排空和查询的间隙实测约 93.8 ms，所以打满时 wire 在 99.4–99.5 Gb/s。

每次跑完都会在 REPORT_DIR 下写一份报告 stress_<时间>.html 和同名的 .json(原始数据)。报告
是一个不依赖网络的单文件网页，用浏览器打开：带宽、丢包、主机侧的检查结果、帧的去向，
以及整个过程逐遍的线路速率和板端丢帧。

Expected result on the reference setup (MTU 1500, 4 sender threads, 20 s):

    214 passes, 214.0 GiB in 20.08 s = goodput 91.5 Gb/s, wire 99.4 Gb/s
    sent=224395264 on_wire=224395483 board_rx=224395264 bad_fcs=0 fifo_full=0 rejected=0 stored=224395264 loss=0 (0.000e+00)
    PASS: 99.4 Gb/s on the wire for 20 s, 0 of 224395264 frames lost

Edit the constants below, then run the file without command-line arguments.
"""

from __future__ import annotations

import json
import platform
import subprocess
import time
from pathlib import Path

import numpy as np

from dr47 import Dr47Device, DriverError, __version__
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
DURATION_S = 20.0                 # 持续发送的时间(s)；发完当前这一遍才停
SENDER_THREADS = 4                # 发送线程数；要足够把链路打满
MAX_LOSS_RATE = 0.0               # 丢包率高于该值判 FAIL；硬件在线速下应当一帧不丢
MIN_WIRE_RATE_GBPS = 99.0         # 线路速率低于该值说明主机没把链路打满，结果不代表硬件，判 FAIL
REPORT_DIR = "stress_reports"     # 每次跑完把报告(.html)和原始数据(.json)写到这个目录；"" = 不写

UDP_TIMEOUT_S = 2.0
UDP_RETRIES = 3
SETTLE_POLL_S = 0.02              # 发完后轮询板端计数器的间隔
SEND_BUFFER_BYTES = 1 << 20       # socket 发送缓冲：够把链路打满，积压又少到能在两遍之间排空
MAX_PASS_BYTES = 1 << 30          # 一遍最多发送的数据量：约 0.09 s，远短于内核强制重选队列的 1 s
DRAIN_TIMEOUT_S = 1.0             # 等 socket 排空的上限；实测最长只等 0.1 ms
DAC_BEAT_BYTES = 256              # 8 channels x 8 I/Q samples x 2 int16
# 一帧在线路上除数据以外占用的字节：批量头 + UDP + IPv4 + 以太网头 + FCS + 前导码 + 帧间隔
FRAME_OVERHEAD_BYTES = WAVE_BULK_HEADER_BYTES + 8 + 20 + 14 + 4 + 8 + 12
# 板端计数器都是 32 位；每发完一遍采样一次并按模 2**32 累加，线速下也不会回绕丢数。
COUNTER_KEYS = ("bulk_rx_frames", "bulk_rx_dropped_bad", "bulk_rx_dropped_full",
                "bulk_frames_ok", "bulk_frames_duplicate", "bulk_frames_stale", "bulk_frames_rejected")


def make_image() -> np.ndarray:
    """IMAGE_MIB of a counting pattern; the content does not affect the result."""
    return np.arange((IMAGE_MIB << 20) // 8, dtype="<u8").view(np.uint8)


def host_setting(name: str) -> int | None:
    """A /proc/sys/net/core value of this host, or None when it cannot be read."""
    try:
        return int(Path(f"/proc/sys/net/core/{name}").read_text().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def nic_frames_sent() -> int | None:
    """Frames the card has put on the wire so far (tx_packets_phy), or None when it cannot be read."""
    try:
        text = subprocess.run(["ethtool", "-S", UDP_INTERFACE], capture_output=True, text=True,
                              timeout=5, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in text.splitlines():
        name, _, value = line.partition(":")
        if name.strip() == "tx_packets_phy":
            return int(value)
    return None


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


def wait_sent(sender: BulkSender) -> float:
    """Wait until the socket holds no unsent frame; returns the seconds waited."""
    began = now = time.perf_counter()
    while sender.queued_bytes():
        now = time.perf_counter()
        if now - began > DRAIN_TIMEOUT_S:
            raise RuntimeError("the network card did not send the queued frames (link down?)")
    return now - began


def run_load(device: Dr47Device, image: np.ndarray, payload_bytes: int, session: int) -> dict:
    """The load: the image over and over at line rate for DURATION_S in one session."""
    begun = device.begin_waveform(
        session=session, total_bytes=image.size, channel_mask=0xFF,
        total_beats=image.size // DAC_BEAT_BYTES, loop_count=1,
        layout=WAVE_LAYOUT_INTERLEAVED_512B_BULK)
    if int(begun["status"]) != 0:
        raise RuntimeError(f"BEGIN failed with status {begun['status']} "
                           "(bitstream without the bulk path?)")
    sender = BulkSender(BOARD_IP, BOARD_PORT + WAVE_BULK_PORT_OFFSET, udp_interface=UDP_INTERFACE,
                        udp_source_ip=UDP_SOURCE_IP, threads=SENDER_THREADS, accelerate=True,
                        send_buffer_bytes=SEND_BUFFER_BYTES)
    total = dict.fromkeys(COUNTER_KEYS, 0)
    sent, offset, drain_wait, timeline = 0, 0, 0.0, []

    def accumulate(sample: dict, last: dict) -> dict:
        for key in COUNTER_KEYS:
            total[key] += (int(sample[key]) - int(last[key])) & 0xFFFF_FFFF
        return sample

    def dropped() -> list[int]:
        return [total["bulk_rx_dropped_full"], total["bulk_rx_dropped_bad"], total["bulk_frames_rejected"]]

    try:
        last = settled_counters(device, session)      # answered once the session is armed
        wire_before = nic_frames_sent()
        started = now = time.perf_counter()
        while not timeline or now - started < DURATION_S:
            # Every pass starts with an empty socket: when the kernel moves the
            # socket to another transmit queue, no frame of the last pass is
            # left to arrive interleaved with this one.
            drain_wait = max(drain_wait, wait_sent(sender))
            end = min(offset + MAX_PASS_BYTES, image.size)
            # The board writes every frame it receives; frames of a repeated
            # pass are counted as duplicates of an already complete chunk.
            sent += sender.send(image, offset, end, session=session, epoch=0, payload_bytes=payload_bytes)
            offset = end % image.size
            last = accumulate(bulk_counters(device, session), last)
            now = time.perf_counter()
            # One row per pass: time since the load began, then the frames
            # sent / fifo_full / bad_fcs / rejected so far.
            timeline.append([now - started, sent, *dropped()])
        accumulate(settled_counters(device, session), last)
        # Frames still in the host's transmit queue at the last query are
        # counted while the load settles; they belong to the last pass.
        timeline[-1][2:] = dropped()
        wire_after = nic_frames_sent()
    finally:
        sender.close()
        device.abort()
    elapsed = timeline[-1][0]
    stored = total["bulk_frames_ok"] + total["bulk_frames_duplicate"] + total["bulk_frames_stale"]
    return {
        "threads": SENDER_THREADS, "elapsed_s": elapsed, "passes": len(timeline),
        "goodput_gbps": sent * payload_bytes * 8 / elapsed / 1e9,
        "wire_gbps": sent * (payload_bytes + FRAME_OVERHEAD_BYTES) * 8 / elapsed / 1e9,
        "sent": sent, "on_wire": None if None in (wire_before, wire_after) else wire_after - wire_before,
        "board_rx": total["bulk_rx_frames"], "bad_fcs": total["bulk_rx_dropped_bad"],
        "fifo_full": total["bulk_rx_dropped_full"], "rejected": total["bulk_frames_rejected"],
        "stored": stored, "loss_rate": (sent - stored) / sent,
        "drain_wait_ms": drain_wait * 1000,
        "timeline": timeline,
    }


def report(measured: dict, payload_bytes: int) -> None:
    """Print the measurement."""
    sent = measured["sent"]
    on_wire = "n/a" if measured["on_wire"] is None else str(measured["on_wire"])
    print(f"    {measured['passes']} passes, {sent * payload_bytes / 2**30:.1f} GiB in "
          f"{measured['elapsed_s']:.2f} s = goodput {measured['goodput_gbps']:.1f} Gb/s, "
          f"wire {measured['wire_gbps']:.1f} Gb/s")
    print(f"    sent={sent} on_wire={on_wire} board_rx={measured['board_rx']} "
          f"bad_fcs={measured['bad_fcs']} fifo_full={measured['fifo_full']} "
          f"rejected={measured['rejected']} stored={measured['stored']} "
          f"loss={sent - measured['stored']} ({measured['loss_rate']:.3e})")


def verdict(measured: dict) -> tuple[bool, str]:
    """Whether the run passes, and the sentence printed after PASS or FAIL."""
    sent, wire_rate = measured["sent"], measured["wire_gbps"]
    lost = sent - measured["stored"]
    # A run in which the host lost frames or left the link partly idle says
    # nothing about the hardware, so it does not pass either.
    if measured["on_wire"] is not None and measured["on_wire"] < sent:
        return False, (f"the host dropped {sent - measured['on_wire']} frames before the wire, "
                       "so the result does not show the hardware")
    if measured["loss_rate"] > MAX_LOSS_RATE:
        return False, (f"{lost} of {sent} frames lost ({measured['loss_rate']:.3e}): "
                       f"not delivered={max(sent - measured['board_rx'], 0)}, bad_fcs={measured['bad_fcs']}, "
                       f"fifo_full={measured['fifo_full']}, rejected={measured['rejected']}")
    if wire_rate < MIN_WIRE_RATE_GBPS:
        buffer_limit = host_setting("wmem_max")
        hint = ("" if buffer_limit is None or buffer_limit >= SEND_BUFFER_BYTES else
                f" (net.core.wmem_max={buffer_limit} is below the {SEND_BUFFER_BYTES}-byte send buffer this test needs)")
        return False, (f"the host did not fill the link: {wire_rate:.1f} Gb/s on the wire is below "
                       f"MIN_WIRE_RATE_GBPS={MIN_WIRE_RATE_GBPS:g}, so the result does not show the "
                       f"hardware's limit{hint}")
    return True, (f"{wire_rate:.1f} Gb/s on the wire for {measured['elapsed_s']:.0f} s, "
                  f"{lost} of {sent} frames lost")


def write_report(result: dict) -> Path:
    """Write the run to REPORT_DIR as one self-contained page plus its raw data; returns the page."""
    stamp = result["started"].replace("-", "").replace(":", "").replace(" ", "_")
    page = Path(REPORT_DIR) / f"stress_{stamp}.html"
    page.parent.mkdir(parents=True, exist_ok=True)
    data = json.dumps(result)
    page.with_suffix(".json").write_text(data + "\n", encoding="utf-8")
    # "<" only occurs inside JSON strings; escaped, no text can end the data block.
    page.write_text(REPORT_PAGE.replace("__REPORT_DATA__", data.replace("<", "\\u003c")), encoding="utf-8")
    return page


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
    result = {
        "started": time.strftime("%Y-%m-%d %H:%M:%S"), "passed": False, "message": "",
        "driver": __version__, "kernel": platform.release(), "board": {},
        "config": {
            "board_ip": BOARD_IP, "interface": UDP_INTERFACE, "payload_bytes": payload_bytes,
            "frame_wire_bytes": payload_bytes + FRAME_OVERHEAD_BYTES, "image_mib": IMAGE_MIB,
            "duration_s": DURATION_S, "send_buffer_bytes": SEND_BUFFER_BYTES,
            "max_loss_rate": MAX_LOSS_RATE, "min_wire_rate_gbps": MIN_WIRE_RATE_GBPS,
            "txq_reselection_ms": host_setting("txq_reselection_ms"),
        },
        "measured": None,
    }
    try:
        print(f"[2/3] connect {BOARD_IP}:{BOARD_PORT}")
        device.connect()
        device.abort()
        identity = device.status(refresh=False).capabilities
        result["board"] = {"build_profile": identity.build_profile,
                           "source_commit": f"{identity.source_commit_id:08x}"}

        print(f"[3/3] send {payload_bytes}-byte datagrams from {SENDER_THREADS} threads for {DURATION_S:g} s")
        result["measured"] = run_load(device, image, payload_bytes, session=1)
        report(result["measured"], payload_bytes)
        result["passed"], result["message"] = verdict(result["measured"])
    except (DriverError, RuntimeError, TimeoutError, ValueError) as error:
        result["message"] = str(error)
    finally:
        if device.connected:
            try:
                device.abort()
            except DriverError as error:
                print(f"WARN: cleanup failed: {error}")
        device.close()
    print(("PASS: " if result["passed"] else "FAIL: ") + result["message"])
    if REPORT_DIR and result["measured"]:
        try:
            print(f"report: {write_report(result)}")
        except OSError as error:
            print(f"WARN: report not written: {error}")
    return 0 if result["passed"] else 1


# The report page.  Everything it needs is in this one file; the run is the JSON
# block near the end, and the script below it draws the page from that.
REPORT_PAGE = r"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>100G 压测报告</title>
<style>
:root {
  color-scheme: light dark;
  --page: #f9f9f7; --surface: #fcfcfb; --ink: #0b0b0b; --ink-2: #52514e; --muted: #898781;
  --grid: #e1e0d9; --axis: #c3c2b7; --border: rgba(11, 11, 11, .10); --wash: rgba(11, 11, 11, .04);
  --rate: #2a78d6;
  --fifo_full: #eb6834; --bad_fcs: #1baf7a; --rejected: #eda100; --not_delivered: #e87ba4;
  --good: #0ca30c; --critical: #d03b3b;
}
@media (prefers-color-scheme: dark) {
  :root {
    --page: #0d0d0d; --surface: #1a1a19; --ink: #ffffff; --ink-2: #c3c2b7;
    --grid: #2c2c2a; --axis: #383835; --border: rgba(255, 255, 255, .10); --wash: rgba(255, 255, 255, .06);
    --rate: #3987e5;
    --fifo_full: #d95926; --bad_fcs: #199e70; --rejected: #c98500; --not_delivered: #d55181;
  }
}
* { box-sizing: border-box; }
body { margin: 0; padding: 24px 16px 40px; background: var(--page); color: var(--ink);
       font: 14px/1.45 system-ui, -apple-system, "Segoe UI", "PingFang SC", "Microsoft YaHei",
             "Noto Sans CJK SC", sans-serif; }
main { max-width: 1080px; margin: 0 auto; display: grid; gap: 16px; }
h1 { margin: 0; font-size: 20px; font-weight: 600; }
h2 { margin: 0; font-size: 14px; font-weight: 600; }
p { margin: 0; }
.note { color: var(--ink-2); font-size: 12px; }
.title { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; margin-bottom: 6px; }
.verdict { display: inline-flex; align-items: center; gap: 6px; padding: 2px 10px 2px 3px;
           border: 1px solid var(--border); border-radius: 999px; font-size: 13px; font-weight: 600; }
.mark { flex: none; display: grid; place-items: center; align-self: center; width: 18px; height: 18px;
        border-radius: 50%; background: var(--muted); color: #fff; font-size: 12px; }
.mark.ok { background: var(--good); }
.mark.bad { background: var(--critical); }
section, .tile { min-width: 0; padding: 16px 20px; background: var(--surface);
                 border: 1px solid var(--border); border-radius: 8px; }
.tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px; }
.tile b { display: block; font-size: 26px; font-weight: 600; line-height: 1.3; }
.cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 16px; }
.list { margin-top: 6px; }
.list div { display: flex; align-items: baseline; gap: 10px; padding: 7px 0; border-bottom: 1px solid var(--grid); }
.list div:last-child { border-bottom: 0; }
.list .label { flex: 1; }
.list small { display: block; color: var(--ink-2); font-size: 12px; }
.list b { font-weight: 600; font-variant-numeric: tabular-nums; }
.key { flex: none; display: inline-block; align-self: center; width: 10px; height: 10px; border-radius: 2px; }
#reselection { margin-top: 8px; }
.legend { display: flex; flex-wrap: wrap; gap: 4px 16px; margin-top: 10px; color: var(--ink-2); font-size: 12px; }
.legend .key { margin-right: 6px; }
#timeline { margin-top: 10px; }
svg { display: block; }
svg text { fill: var(--muted); font-size: 11px; font-variant-numeric: tabular-nums; }
svg .head { fill: var(--ink-2); font-size: 12px; }
svg .value { fill: var(--ink); }
svg line { stroke: var(--grid); shape-rendering: crispEdges; }
svg .axis { stroke: var(--axis); }
svg .rate { fill: none; stroke: var(--rate); stroke-width: 2; stroke-linejoin: round; stroke-linecap: round; }
svg .dot { fill: var(--rate); stroke: var(--surface); stroke-width: 2; }
.scroll { margin-top: 10px; overflow-x: auto; }
table { width: 100%; border-collapse: collapse; font-size: 12px; font-variant-numeric: tabular-nums; white-space: nowrap; }
th, td { padding: 5px 6px; border-bottom: 1px solid var(--grid); text-align: right; }
th { color: var(--ink-2); font-weight: 500; }
.tip { position: fixed; z-index: 1; min-width: 150px; padding: 8px 10px; pointer-events: none;
       background: var(--surface); border: 1px solid var(--border); border-radius: 6px;
       box-shadow: 0 4px 16px rgba(0, 0, 0, .14); font-size: 12px; }
.tip[hidden] { display: none; }
.tip div { display: flex; align-items: center; gap: 6px; white-space: nowrap; }
.tip div:first-child { margin-bottom: 4px; color: var(--ink-2); }
.tip i { width: 10px; height: 2px; border-radius: 1px; }
.tip span { color: var(--ink-2); }
</style>
</head>
<body>
<main>
  <header>
    <div class="title"><h1>100G 压测报告</h1><span id="verdict" class="verdict"></span></div>
    <p id="message"></p>
    <p id="meta" class="note"></p>
  </header>
  <div id="tiles" class="tiles"></div>
  <div class="cards">
    <section>
      <h2>主机侧检查</h2>
      <p class="note">压测要反映的是硬件。下面几项确认发送端既没有成为瓶颈，也没有打乱帧的顺序。</p>
      <div id="checks" class="list"></div>
      <p id="reselection" class="note"></p>
    </section>
    <section>
      <h2>帧的去向</h2>
      <p class="note">主机发出的每一帧，要么写进了 DDR4，要么丢在下面某个环节。</p>
      <div id="frames" class="list"></div>
    </section>
  </div>
  <section>
    <h2>全程时间线</h2>
    <p class="note">每发完一遍（最多 1 GiB）记一个值。发送端在每一遍开始前都等 socket 排空，帧按地址顺序到达，所以这里出现的丢帧应当按硬件问题排查。</p>
    <div id="timeline" tabindex="0" role="img"
         aria-label="整个压测过程中每一遍的线路速率和板端丢弃的帧数。按左右方向键逐遍查看；合计见下方表格。"></div>
    <div id="legend" class="legend"></div>
  </section>
  <section>
    <h2>数据（与终端输出相同）</h2>
    <div class="scroll"><table id="table"></table></div>
  </section>
</main>
<div id="tip" class="tip" hidden></div>
<script type="application/json" id="report-data">__REPORT_DATA__</script>
<script>
const run = JSON.parse(document.getElementById("report-data").textContent);
const measured = run.measured, config = run.config;
const LINE_RATE = 100;            // Gb/s: the limit of the link, on the wire
// Where a frame can be lost, in the order the charts stack and colour the stages.
const STAGES = [["fifo_full", "FIFO 满"], ["bad_fcs", "坏帧 (FCS)"], ["rejected", "写入器拒收"],
                ["not_delivered", "没到板卡"]];
const BOARD_DROPS = STAGES.slice(0, 3);       // the stages the board counts pass by pass

const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
};
const svg = (tag, attributes) => {
  const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
  for (const name in attributes) node.setAttribute(name, attributes[name]);
  return node;
};
const count = n => n == null ? "n/a" : n.toLocaleString("en-US");
const gbps = v => v.toFixed(1);
const tenths = v => v.toLocaleString("en-US", {minimumFractionDigits: 1, maximumFractionDigits: 1});
const share = r => r ? `${(r * 1e6).toLocaleString("en-US", {maximumSignificantDigits: 3})} ppm` : "0";
// The largest f(item); a run can have more passes than a call can take arguments.
const most = (items, f) => items.reduce((largest, item) => Math.max(largest, f(item)), 0);
const niceCeil = v => {
  if (v <= 0) return 0;
  const unit = 10 ** Math.floor(Math.log10(v));
  return [1, 2, 5, 10].map(m => m * unit).find(m => m >= v);
};
// A pass / fail / unknown mark: the colour never stands alone, the sign says the same.
const mark = ok => el("span", `mark ${ok == null ? "" : ok ? "ok" : "bad"}`, ok == null ? "–" : ok ? "✓" : "✕");
const swatch = key => {
  const node = el("span", "key");
  if (key) node.style.background = `var(--${key})`;
  return node;
};

// One tooltip for the page: a title, then rows of [value, label, colour key].
const tip = document.getElementById("tip");
function showTip(x, y, title, rows) {
  tip.replaceChildren(el("div", "", title));
  for (const [value, label, key] of rows) {
    const row = el("div"), line = el("i");
    if (key) line.style.background = `var(--${key})`;
    row.append(line, el("b", "", value), el("span", "", label));
    tip.append(row);
  }
  tip.hidden = false;
  const box = tip.getBoundingClientRect();
  tip.style.left = `${Math.max(8, Math.min(x + 14, innerWidth - box.width - 8))}px`;
  tip.style.top = `${Math.max(8, Math.min(y + 14, innerHeight - box.height - 8))}px`;
}
const hideTip = () => { tip.hidden = true; };

// ---- header and headline numbers
document.getElementById("verdict").append(mark(run.passed), run.passed ? "PASS" : "FAIL");
// The sentence is the one the terminal printed, so the two can be matched.
document.getElementById("message").textContent = `终端结论：${run.passed ? "PASS" : "FAIL"}: ${run.message}`;
document.getElementById("meta").textContent = [
  run.started, `板卡 ${config.board_ip}，build ${run.board.source_commit} (${run.board.build_profile})`,
  `驱动 ${run.driver}`, `网卡 ${config.interface}，每帧 ${config.payload_bytes} 字节数据`,
  `图像 ${config.image_mib} MiB`, `${measured.threads} 个发送线程`, `Linux ${run.kernel}`,
].join(" · ");

measured.not_delivered = Math.max(measured.sent - measured.board_rx, 0);
const lost = measured.sent - measured.stored;
for (const [label, value, note] of [
  ["线路速率", `${gbps(measured.wire_gbps)} Gb/s`,
   `线速 ${LINE_RATE} Gb/s 的 ${(measured.wire_gbps / LINE_RATE * 100).toFixed(1)}%`],
  ["有效速率 (goodput)", `${gbps(measured.goodput_gbps)} Gb/s`, "只算波形数据"],
  ["丢包率", share(measured.loss_rate),
   `丢 ${count(lost)} 帧 · 判据：不高于 ${share(config.max_loss_rate)}`],
  ["发送总量", `${tenths(measured.sent * config.payload_bytes / 2 ** 30)} GiB`,
   `${count(measured.sent)} 帧 · ${tenths(measured.elapsed_s)} s`],
]) {
  const tile = el("div", "tile");
  tile.append(el("div", "note", label), el("b", "", value), el("div", "note", note));
  document.getElementById("tiles").append(tile);
}

// ---- host side: was the sender neither a bottleneck nor a source of disorder
function check(ok, label, detail) {
  const row = el("div"), text = el("span", "label", label);
  text.append(el("small", "", detail));
  row.append(mark(ok), text);
  document.getElementById("checks").append(row);
}
check(measured.wire_gbps >= config.min_wire_rate_gbps, "链路已打满",
      `线路速率 ${gbps(measured.wire_gbps)} Gb/s，判据是不低于 ${config.min_wire_rate_gbps} Gb/s`);
const wireOk = measured.on_wire == null ? null : measured.on_wire >= measured.sent;
check(wireOk, "主机没有丢帧", wireOk == null ? "读不到网卡的发送计数"
      : `网卡发出 ${count(measured.on_wire)} 帧（含控制报文），${wireOk ? "不少于" : "少于"}交给内核的 ${count(measured.sent)} 帧`);
check(true, "每一遍开始前 socket 已排空",
      `最长等了 ${measured.drain_wait_ms.toFixed(2)} ms；发送缓冲 ${config.send_buffer_bytes / 1024} KiB`);
if (config.txq_reselection_ms != null) {
  document.getElementById("reselection").textContent = config.txq_reselection_ms
    ? `这台主机的内核每 ${config.txq_reselection_ms} ms 强制为 socket 重选一次网卡发送队列 (net.core.txq_reselection_ms)。`
      + "重选时 socket 里如果还有积压，新旧队列的帧会交错到达；排空之后再发就不会。"
    : "这台主机已关闭发送队列的定时重选 (net.core.txq_reselection_ms = 0)。";
}

// ---- where every frame went
for (const [key, label, value] of [[null, "主机发出", measured.sent], [null, "写入 DDR4", measured.stored],
                                   ...STAGES.map(([key, label]) => [key, label, measured[key]])]) {
  const row = el("div");
  row.append(swatch(key), el("span", "label", label), el("b", "", count(value)));
  document.getElementById("frames").append(row);
}

// ---- over the run: every pass
const passes = [];
measured.timeline.forEach((row, index) => {
  const before = index ? measured.timeline[index - 1] : [0, 0, 0, 0, 0];
  const pass = {number: index + 1, t0: before[0], t1: row[0],
                wire: (row[1] - before[1]) * config.frame_wire_bytes * 8 / (row[0] - before[0]) / 1e9};
  BOARD_DROPS.forEach(([key], i) => { pass[key] = row[2 + i] - before[2 + i]; });
  pass.dropped = pass.fifo_full + pass.bad_fcs + pass.rejected;
  passes.push(pass);
});
const timeline = document.getElementById("timeline");
let selected = 0, selectPass = () => {};

function drawTimeline() {
  const width = Math.max(timeline.clientWidth, 320), left = 48, right = 12;
  const rateTop = 26, rateHeight = 120, dropTop = rateTop + rateHeight + 46, dropHeight = 90;
  const bottom = dropTop + dropHeight, end = passes[passes.length - 1].t1;
  const x = t => left + t / end * (width - left - right);
  const rateMax = Math.max(LINE_RATE, most(passes, pass => pass.wire));
  const yRate = v => rateTop + rateHeight * (1 - v / rateMax);
  const dropMax = niceCeil(most(passes, pass => pass.dropped));
  const yDrop = v => dropTop + dropHeight * (1 - v / (dropMax || 1));
  const root = svg("svg", {width, height: bottom + 24});
  const line = (x1, y1, x2, y2, className) => root.append(svg("line", {x1, y1, x2, y2, class: className || ""}));
  const text = (x, y, string, anchor, className) => {
    const node = svg("text", {x, y, "text-anchor": anchor, class: className || ""});
    node.textContent = string;
    root.append(node);
  };

  text(left, 12, "每一遍的线路速率 (Gb/s)", "start", "head");
  for (const tick of [0, LINE_RATE / 2, LINE_RATE]) {
    line(left, yRate(tick), width - right, yRate(tick), tick ? "" : "axis");
    text(left - 6, yRate(tick) + 4, tick, "end");
  }
  text(left, dropTop - 22, "每一遍板端丢弃的帧数", "start", "head");
  for (const tick of !dropMax ? [0] : dropMax % 2 ? [0, dropMax] : [0, dropMax / 2, dropMax]) {
    line(left, yDrop(tick), width - right, yDrop(tick), tick ? "" : "axis");
    text(left - 6, yDrop(tick) + 4, count(tick), "end");
  }
  const every = [1, 2, 5, 10, 20, 30, 60, 120, 300, 600, 1800, 3600].find(seconds => end / seconds <= 8) || 7200;
  for (let t = 0; t <= end; t += every) text(x(t), bottom + 16, `${t} s`, "middle");
  // The rate of a pass holds for the whole pass, so the line is drawn in steps.
  root.append(svg("path", {class: "rate", d: passes.map((pass, i) =>
    `${i ? "L" : "M"}${x(pass.t0).toFixed(1)},${yRate(pass.wire).toFixed(1)}H${x(pass.t1).toFixed(1)}`).join("")}));

  let tallest = null;
  for (const pass of passes) {
    if (!pass.dropped) continue;
    if (!tallest || pass.dropped > tallest.dropped) tallest = pass;
    // A thin column per pass, stacked by stage with a 2px gap; the top end is rounded.
    const w = Math.min(24, Math.max(2, x(pass.t1) - x(pass.t0) - 2)), x0 = (x(pass.t0) + x(pass.t1) - w) / 2;
    const parts = BOARD_DROPS.filter(([key]) => pass[key]);
    let below = 0;
    parts.forEach(([key], i) => {
      const y1 = yDrop(below) - (i ? 2 : 0), top = i === parts.length - 1;
      below += pass[key];
      const y0 = Math.min(yDrop(below), y1 - 2), r = top ? Math.min(4, w / 2, y1 - y0) : 0;
      root.append(svg("path", {fill: `var(--${key})`, d:
        `M${x0},${y1}V${y0 + r}Q${x0},${y0} ${x0 + r},${y0}H${x0 + w - r}Q${x0 + w},${y0} ${x0 + w},${y0 + r}V${y1}Z`}));
    });
  }
  if (tallest) {
    const middle = (x(tallest.t0) + x(tallest.t1)) / 2;
    text(Math.max(left + 24, Math.min(middle, width - right - 24)), yDrop(tallest.dropped) - 5,
         count(tallest.dropped), "middle", "value");
  } else {
    text((left + width - right) / 2, dropTop + dropHeight / 2, "板端没有丢帧", "middle");
  }

  // The pointer only has to pick a time: the crosshair snaps to that pass.
  const cross = svg("line", {y1: rateTop, y2: bottom, class: "axis", visibility: "hidden"});
  const dot = svg("circle", {r: 4, class: "dot", visibility: "hidden"});
  const target = svg("rect", {x: left, y: rateTop, width: width - left - right, height: bottom - rateTop,
                              fill: "transparent"});
  root.append(cross, dot, target);
  selectPass = (index, clientX, clientY) => {
    selected = Math.max(0, Math.min(index, passes.length - 1));
    const pass = passes[selected], middle = (x(pass.t0) + x(pass.t1)) / 2, box = root.getBoundingClientRect();
    for (const name of ["x1", "x2"]) cross.setAttribute(name, middle);
    dot.setAttribute("cx", middle);
    dot.setAttribute("cy", yRate(pass.wire));
    for (const shape of [cross, dot]) shape.setAttribute("visibility", "visible");
    showTip(clientX ?? box.left + middle, clientY ?? box.top + rateTop,
            `第 ${pass.number} / ${passes.length} 遍 · ${pass.t0.toFixed(2)} s`,
            [[`${gbps(pass.wire)} Gb/s`, "线路速率", "rate"],
             ...BOARD_DROPS.map(([key, label]) => [count(pass[key]), label, key])]);
  };
  const leave = () => {
    for (const shape of [cross, dot]) shape.setAttribute("visibility", "hidden");
    hideTip();
  };
  target.addEventListener("pointermove", event => {
    const t = (event.clientX - root.getBoundingClientRect().left - left) / (width - left - right) * end;
    const index = passes.findIndex(pass => pass.t1 >= t);
    selectPass(index < 0 ? passes.length - 1 : index, event.clientX, event.clientY);
  });
  target.addEventListener("pointerleave", leave);
  timeline.onblur = leave;
  timeline.replaceChildren(root);
}
drawTimeline();
for (const [key, label] of BOARD_DROPS) {
  const item = el("span", "", label);
  item.prepend(swatch(key));
  document.getElementById("legend").append(item);
}
addEventListener("resize", drawTimeline);
timeline.addEventListener("focus", () => selectPass(selected));
timeline.addEventListener("keydown", event => {
  const move = {ArrowLeft: -1, ArrowRight: 1}[event.key];
  if (!move) return;
  event.preventDefault();
  selectPass(selected + move);
});

// ---- the same numbers as the console output, as a table; the counters keep their console names
const columns = [
  ["线程数", measured.threads], ["遍数", count(measured.passes)], ["时间 (s)", measured.elapsed_s.toFixed(2)],
  ["goodput (Gb/s)", gbps(measured.goodput_gbps)], ["wire (Gb/s)", gbps(measured.wire_gbps)],
  ["sent", count(measured.sent)], ["on_wire", count(measured.on_wire)], ["board_rx", count(measured.board_rx)],
  ["bad_fcs", count(measured.bad_fcs)], ["fifo_full", count(measured.fifo_full)],
  ["rejected", count(measured.rejected)], ["stored", count(measured.stored)], ["loss", count(lost)],
  ["丢包率", measured.loss_rate ? measured.loss_rate.toExponential(3) : "0"],
];
const table = document.getElementById("table"), header = table.insertRow(), values = table.insertRow();
for (const [name, value] of columns) {
  header.append(el("th", "", name));
  values.append(el("td", "", value));
}
</script>
</body>
</html>
"""


if __name__ == "__main__":
    raise SystemExit(run())
