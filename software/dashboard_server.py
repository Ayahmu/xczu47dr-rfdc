#!/usr/bin/env python3
import csv
import json
import os
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parent
PROJECT_ROOT = ROOT.parent
LOG_DIR = Path(os.environ.get("BW_LOG_DIR", PROJECT_ROOT / "logs")).resolve()
HOST = os.environ.get("BW_DASH_HOST", "127.0.0.1")
PORT = int(os.environ.get("BW_DASH_PORT", "8081"))
MAX_ROWS = int(os.environ.get("BW_DASH_MAX_ROWS", "7200"))
WINDOW_SECONDS = int(os.environ.get("BW_DASH_WINDOW_SECONDS", "30"))


def latest(pattern):
    files = sorted(LOG_DIR.glob(pattern), key=lambda p: p.stat().st_mtime if p.exists() else 0)
    return files[-1] if files else None


def read_csv(path, limit=MAX_ROWS):
    if not path or not path.exists():
        return []
    with path.open(newline="") as f:
        rows = list(csv.DictReader(f))
    return rows[-limit:]


def to_float(value, default=0.0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def to_int(value, default=0):
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return default


def delta_counter(now, prev):
    if now >= prev:
        return now - prev
    return (now + (1 << 32)) - prev


def normalize_samples(rows):
    out = []
    elapsed = 0.0

    for idx, row in enumerate(rows):
        now_total = to_int(row.get("total_bytes"))
        now_bursts = to_int(row.get("total_bursts"))
        now_stalls = to_int(row.get("total_stalls"))
        now_under = to_int(row.get("total_underflows"))
        dt = 1.0
        delta_bytes = to_int(row.get("delta_bytes"))
        delta_bursts = to_int(row.get("delta_bursts"))
        delta_stalls = to_int(row.get("delta_stalls"))
        delta_under = to_int(row.get("delta_underflows"))

        elapsed += dt if idx else 0.0
        second = str(int(round(elapsed)) + 1)
        gbps = delta_bytes / dt / 1e9 if dt > 0 else 0.0
        gibps = delta_bytes / dt / (1024.0 ** 3) if dt > 0 else 0.0

        fixed = dict(row)
        fixed.update({
            "second": second,
            "sample": row.get("sample") or second,
            "elapsed_seconds": f"{elapsed:.3f}",
            "dt_seconds": f"{dt:.3f}",
            "total_bytes": str(now_total),
            "delta_bytes": str(delta_bytes),
            "gbps": f"{gbps:.6f}",
            "gibps": f"{gibps:.6f}",
            "total_bursts": str(now_bursts),
            "delta_bursts": str(delta_bursts),
            "total_stalls": str(now_stalls),
            "delta_stalls": str(delta_stalls),
            "total_underflows": str(now_under),
            "delta_underflows": str(delta_under),
            "status": row.get("status", ""),
        })
        out.append(fixed)
        _ = (now_bursts, now_stalls, now_under)
    return out


def build_sample_windows(samples, window_seconds=WINDOW_SECONDS):
    if not samples or window_seconds <= 0:
        return []
    windows = []
    index = 1
    acc_seconds = 0.0
    acc_bytes = 0
    acc_bursts = 0
    acc_stalls = 0
    acc_under = 0

    for row in samples:
        dt = to_float(row.get("dt_seconds"), 1.0)
        acc_seconds += dt
        acc_bytes += to_int(row.get("delta_bytes"))
        acc_bursts += to_int(row.get("delta_bursts"))
        acc_stalls += to_int(row.get("delta_stalls"))
        acc_under += to_int(row.get("delta_underflows"))
        if acc_seconds >= window_seconds:
            gbps = acc_bytes / acc_seconds / 1e9 if acc_seconds else 0.0
            gibps = acc_bytes / acc_seconds / (1024.0 ** 3) if acc_seconds else 0.0
            windows.append({
                "host_time": row.get("host_time", ""),
                "index": str(index),
                "seconds": f"{acc_seconds:.3f}",
                "end_second": row.get("second", ""),
                "bytes": str(acc_bytes),
                "gbps": f"{gbps:.6f}",
                "gibps": f"{gibps:.6f}",
                "bursts": str(acc_bursts),
                "stalls": str(acc_stalls),
                "underflows": str(acc_under),
                "status": row.get("status", ""),
                "source": "server",
            })
            index += 1
            acc_seconds = 0.0
            acc_bytes = 0
            acc_bursts = 0
            acc_stalls = 0
            acc_under = 0
    return windows


def summarize(samples, windows, channels):
    latest_sample = samples[-1] if samples else {}
    latest_window = windows[-1] if windows else {}
    gbps_values = [to_float(r.get("gbps")) for r in samples if r.get("gbps")]
    window_values = [to_float(r.get("gbps")) for r in windows if r.get("gbps")]
    last_channels = {}
    for row in channels:
        ch = row.get("ch")
        if ch:
            last_channels[ch] = row

    return {
        "latest_gbps": to_float(latest_sample.get("gbps")),
        "latest_window_gbps": to_float(latest_window.get("gbps")),
        "avg_gbps": sum(gbps_values) / len(gbps_values) if gbps_values else 0.0,
        "min_gbps": min(gbps_values) if gbps_values else 0.0,
        "max_gbps": max(gbps_values) if gbps_values else 0.0,
        "avg_window_gbps": sum(window_values) / len(window_values) if window_values else 0.0,
        "total_bytes": to_int(latest_sample.get("total_bytes")),
        "total_bursts": to_int(latest_sample.get("total_bursts")),
        "total_stalls": to_int(latest_sample.get("total_stalls")),
        "total_underflows": to_int(latest_sample.get("total_underflows")),
        "delta_stalls": to_int(latest_sample.get("delta_stalls")),
        "delta_underflows": to_int(latest_sample.get("delta_underflows")),
        "status": latest_sample.get("status", ""),
        "sample_count": len(samples),
        "window_count": len(windows),
        "channel_count": len(last_channels),
    }


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/metrics":
            sample_file = latest("bandwidth_[0-9]*.csv")
            channel_file = latest("bandwidth_channels_*.csv")
            window_file = latest("bandwidth_windows_*.csv")
            samples = normalize_samples(read_csv(sample_file))
            channels = read_csv(channel_file)
            windows = build_sample_windows(samples)
            payload = {
                "files": {
                    "samples": str(sample_file) if sample_file else "",
                    "channels": str(channel_file) if channel_file else "",
                    "windows": str(window_file) if window_file else "",
                    "log_dir": str(LOG_DIR),
                },
                "summary": summarize(samples, windows, channels),
                "samples": samples,
                "channels": channels,
                "windows": windows,
            }
            data = json.dumps(payload).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)
            return
        if parsed.path == "/":
            self.path = "/dashboard.html"
        super().do_GET()


def main():
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    port = PORT
    while True:
        try:
            server = ThreadingHTTPServer((HOST, port), Handler)
            break
        except OSError as exc:
            if exc.errno not in (48, 98, 10048):
                raise
            port += 1
            if port > PORT + 20:
                raise RuntimeError(f"could not bind dashboard port in {PORT}..{PORT + 20}") from exc
    print(f"Dashboard: http://{HOST}:{port}/")
    print(f"Reading logs from: {LOG_DIR}")
    server.serve_forever()


if __name__ == "__main__":
    main()
