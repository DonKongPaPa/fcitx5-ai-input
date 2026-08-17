#!/usr/bin/env python3
"""轻量性能采样器（容器内，纯标准库，/proc 直读）。

设计目标：自身开销 <1% CPU，避免监控干扰被测系统（这正是要度量的东西）。
采样对象：按进程名匹配的关键进程（fcitx5、被测合成器、宿主合成器、录屏器、
pipewire、测试应用）的 CPU% 与 RSS；系统级整体 CPU 与内存。

用法:
  sampler.py --out perf.csv --summary perf-summary.json [--interval 0.2]
SIGTERM/SIGINT 时写 summary 退出。
"""
import argparse
import csv
import json
import signal
import sys
import time
from pathlib import Path

# 进程名匹配（comm 截断到 15 字符）
WATCH_PATTERNS = [
    "fcitx5",
    "niri", "kwin_wayland", "gnome-shell", "mutter",
    "sway", "cage",
    "wf-recorder",
    "pipewire", "pipewire-pulse", "wireplumber",
    "testapp-gtk", "testapp-qt",
]
CLK_TCK = 100  # Linux 通用值；容器内 sysconf(SC_CLK_TCK) 同
PAGE_KB = 4


def read_stat(pid):
    try:
        data = Path(f"/proc/{pid}/stat").read_text()
        # comm 可能含空格/括号，从最后一个 ')' 之后切
        tail = data[data.rfind(")") + 2:].split()
        utime, stime = int(tail[11]), int(tail[12])
        return utime + stime
    except (OSError, ValueError, IndexError):
        return None


def read_rss_kb(pid):
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
        return None
    except (OSError, ValueError, IndexError):
        return None


def discover():
    """返回 {pid: comm}，只保留被观察的进程。"""
    found = {}
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            comm = (p / "comm").read_text().strip()
        except OSError:
            continue
        if comm in WATCH_PATTERNS:
            found[int(p.name)] = comm
    return found


def sys_cpu_jiffies():
    try:
        parts = Path("/proc/stat").read_text().splitlines()[0].split()[1:]
        vals = [int(x) for x in parts[:8]]
        idle = vals[3] + vals[4]  # idle + iowait
        return sum(vals), idle
    except (OSError, ValueError, IndexError):
        return None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--summary", required=True)
    ap.add_argument("--interval", type=float, default=0.2)
    args = ap.parse_args()

    running = True

    def stop(*_):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    rows = []
    prev = {}          # pid -> (cpu_jiffies, mono)
    prev_sys = None    # (total, idle, mono)
    acc = {}           # comm -> {"cpu_samples": [], "rss": []}
    sys_acc = {"cpu": [], "mem_kb": []}

    with open(args.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["ts_s", "proc", "cpu_pct", "rss_kb"])
        while running:
            now = time.monotonic()
            procs = discover()
            cur = {}
            for pid, comm in procs.items():
                jif = read_stat(pid)
                if jif is None:
                    continue
                cur[pid] = (comm, jif, read_rss_kb(pid))
                prev_t = prev.get(pid)
                if prev_t is not None:
                    dt = now - prev_t[1]
                    if dt > 0:
                        cpu_pct = (jif - prev_t[0]) / CLK_TCK / dt * 100
                        row = acc.setdefault(comm, {"cpu": [], "rss": []})
                        row["cpu"].append(cpu_pct)
                        if cur[pid][2]:
                            row["rss"].append(cur[pid][2])
                        w.writerow([f"{now:.2f}", comm, f"{cpu_pct:.2f}", cur[pid][2] or 0])
            # 系统级
            total, idle = sys_cpu_jiffies()
            if total is not None and prev_sys is not None:
                dt = now - prev_sys[2]
                if dt > 0:
                    busy = ((total - prev_sys[0]) - (idle - prev_sys[1])) / CLK_TCK / dt * 100
                    sys_acc["cpu"].append(busy)
            try:
                for line in Path("/proc/meminfo").read_text().splitlines():
                    if line.startswith("MemTotal:"):
                        sys_acc["mem_kb"].append(int(line.split()[1]))
            except OSError:
                pass
            prev = {pid: (j, now) for pid, (_, j, _) in cur.items()}
            prev_sys = (total, idle, now)
            time.sleep(args.interval)

    def summarize(vals):
        if not vals:
            return None
        return {"avg": round(sum(vals) / len(vals), 2), "peak": round(max(vals), 2)}

    summary = {
        "interval_ms": int(args.interval * 1000),
        "processes": {
            comm: {
                "cpu_avg_pct": summarize(v["cpu"]) and summarize(v["cpu"])["avg"],
                "rss_peak_mb": summarize(v["rss"])
                and round(summarize(v["rss"])["peak"] / 1024, 1),
            }
            for comm, v in acc.items()
        },
        "system": {
            "cpu_avg_pct": summarize(sys_acc["cpu"]) and summarize(sys_acc["cpu"])["avg"],
            "mem_total_mb": sys_acc["mem_kb"] and round(sys_acc["mem_kb"][0] / 1024, 1),
        },
    }
    Path(args.summary).write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"sampler: {args.summary}", file=sys.stderr)


if __name__ == "__main__":
    main()
