#!/usr/bin/env bash
set -euo pipefail

PORT="${1:-${UART_PORT:-/dev/ttyUSB0}}"
DURATION="${2:-${DURATION:-0}}"
OUT_DIR="${3:-${OUT_DIR:-logs}}"
BAUD="${BAUD:-115200}"

mkdir -p "${OUT_DIR}"
STAMP="$(date +%Y%m%d_%H%M%S)"
RAW_LOG="${OUT_DIR}/bandwidth_${STAMP}.log"
CSV_LOG="${OUT_DIR}/bandwidth_${STAMP}.csv"
CHANNEL_CSV="${OUT_DIR}/bandwidth_channels_${STAMP}.csv"
WINDOW_CSV="${OUT_DIR}/bandwidth_windows_${STAMP}.csv"

if ! command -v python3 >/dev/null; then
  echo "ERROR: python3 not found" >&2
  exit 1
fi

python3 - "${PORT}" "${BAUD}" "${DURATION}" "${RAW_LOG}" "${CSV_LOG}" "${CHANNEL_CSV}" "${WINDOW_CSV}" <<'PY'
import csv
import os
import select
import signal
import subprocess
import sys
import time

port, baud, duration_s, raw_path, csv_path, channel_path, window_path = sys.argv[1:8]
duration_s = int(duration_s)
stop = False

def on_signal(signum, frame):
    global stop
    stop = True

signal.signal(signal.SIGINT, on_signal)
signal.signal(signal.SIGTERM, on_signal)

subprocess.run(["stty", "-F", port, baud, "raw", "-echo", "-ixon", "-ixoff", "-crtscts"], check=True)

start = time.time()
buf = b""
prev_legacy_total = None
prev_legacy_bursts = None
prev_legacy_stalls = None
prev_legacy_underflows = None

with open(port, "rb", buffering=0) as ser, \
     open(raw_path, "a", buffering=1) as raw, \
     open(csv_path, "a", newline="", buffering=1) as csv_file, \
     open(channel_path, "a", newline="", buffering=1) as channel_file, \
     open(window_path, "a", newline="", buffering=1) as window_file:

    csv_writer = csv.writer(csv_file)
    channel_writer = csv.writer(channel_file)
    window_writer = csv.writer(window_file)
    csv_writer.writerow(["host_time", "second", "sample", "total_bytes", "delta_bytes", "gbps", "gibps", "total_bursts", "delta_bursts", "total_stalls", "delta_stalls", "total_underflows", "delta_underflows", "status"])
    channel_writer.writerow(["host_time", "ch", "total_bytes", "bursts", "stalls", "underflows", "fifo_min", "fifo_max"])
    window_writer.writerow(["host_time", "index", "seconds", "bytes", "gbps", "gibps", "bursts", "stalls", "underflows", "status"])

    print(f"Capturing {port} @ {baud} baud")
    print(f"Raw log: {raw_path}")
    print(f"CSV:     {csv_path}")
    print(f"Channel: {channel_path}")
    print(f"Window:  {window_path}")
    if duration_s == 0:
        print("Duration: unlimited; press Ctrl-C to stop")
    else:
        print(f"Duration: {duration_s} seconds")

    while not stop:
        if duration_s and (time.time() - start) >= duration_s:
            break

        ready, _, _ = select.select([ser], [], [], 0.5)
        if not ready:
            continue

        data = ser.read(4096)
        if not data:
            continue
        buf += data

        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            text = line.decode("utf-8", errors="replace").strip("\r")
            if not text:
                continue
            now = time.strftime("%Y-%m-%d %H:%M:%S")
            raw.write(f"{now},{text}\n")
            print(text, flush=True)

            parts = text.split(",")
            if len(parts) == 12 and parts[0] == "csv" and parts[1] != "second":
                try:
                    delta_bytes = int(parts[4])
                    gbps = delta_bytes / 1e9
                    gibps = delta_bytes / (1024.0 ** 3)
                    csv_writer.writerow([now, parts[1], parts[2], parts[3], parts[4], f"{gbps:.6f}", f"{gibps:.6f}", parts[5], parts[6], parts[7], parts[8], parts[9], parts[10], parts[11]])
                except ValueError:
                    pass
            elif len(parts) == 8 and parts[0] == "csv" and parts[1] != "sample":
                try:
                    total_bytes = int(parts[2])
                    total_bursts = int(parts[4])
                    total_stalls = int(parts[5])
                    total_underflows = int(parts[6])
                    if prev_legacy_total is None:
                        delta_bytes = 0
                        delta_bursts = 0
                        delta_stalls = 0
                        delta_underflows = 0
                    else:
                        delta_bytes = max(0, total_bytes - prev_legacy_total)
                        delta_bursts = (total_bursts - prev_legacy_bursts) & 0xffffffff
                        delta_stalls = (total_stalls - prev_legacy_stalls) & 0xffffffff
                        delta_underflows = (total_underflows - prev_legacy_underflows) & 0xffffffff
                    prev_legacy_total = total_bytes
                    prev_legacy_bursts = total_bursts
                    prev_legacy_stalls = total_stalls
                    prev_legacy_underflows = total_underflows
                    gbps = delta_bytes / 1e9
                    gibps = delta_bytes / (1024.0 ** 3)
                    csv_writer.writerow([now, parts[1], parts[1], parts[2], str(delta_bytes), f"{gbps:.6f}", f"{gibps:.6f}", parts[4], str(delta_bursts), parts[5], str(delta_stalls), parts[6], str(delta_underflows), parts[7]])
                except ValueError:
                    pass
            elif len(parts) == 8 and parts[0] == "channel" and parts[1] != "ch":
                channel_writer.writerow([now, parts[1], parts[2], parts[3], parts[4], parts[5], parts[6], parts[7]])
            elif len(parts) == 8 and parts[0] == "win" and parts[1] != "index":
                try:
                    seconds = int(parts[2])
                    byte_count = int(parts[3])
                    gbps = byte_count / seconds / 1e9 if seconds else 0.0
                    gibps = byte_count / seconds / (1024.0 ** 3) if seconds else 0.0
                    window_writer.writerow([now, parts[1], parts[2], parts[3], f"{gbps:.6f}", f"{gibps:.6f}", parts[4], parts[5], parts[6], parts[7]])
                except ValueError:
                    pass

print("Capture stopped")
PY

echo "Saved:"
echo "  ${RAW_LOG}"
echo "  ${CSV_LOG}"
echo "  ${CHANNEL_CSV}"
echo "  ${WINDOW_CSV}"
