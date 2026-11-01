#!/usr/bin/env bash
# card-qml 内存基准（容器内编排）：无头栈同 start-probe.sh（sway 托管嵌套
# niri、software 渲染），feeder 回放 voice-full + pinyin-flow，采样器全程
# 记 quickshell 进程 RSS/CPU。feeder 回放完自行退出（含 TAIL_WAIT）= 结束
# 信号，再采 3s 稳态后收尾。产物：/out/card-perf.csv（宿主侧算 summary）。
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
LOG_DIR="${LOG_DIR:-/tmp/logs}"
OUT_DIR="${OUT_DIR:-/tmp/out}"
mkdir -p "$LOG_DIR" "$OUT_DIR"

export AIINPUT_CARD_SOCK="$XDG_RUNTIME_DIR/aiinput-card-bench.sock"
export LIBGL_ALWAYS_SOFTWARE=1
export QT_QUICK_BACKEND=software
export QT_QPA_PLATFORM=wayland

# —— 无头栈（start-probe.sh 同款，scale 1.0）——
cat > "$LOG_DIR/niri-config.kdl" <<'KDL'
output "*" {
    scale 1.0
}
hotkey-overlay {
    skip-at-startup
}
KDL
cat > "$LOG_DIR/sway-config" <<EOF
output HEADLESS-1 resolution 1920x1080
exec niri -c $LOG_DIR/niri-config.kdl
EOF

WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER_ALLOW_SOFTWARE=1 \
    sway -c "$LOG_DIR/sway-config" >"$LOG_DIR/sway.log" 2>&1 &
HOST_PID=$!

NIRI_SOCK=""
for _ in $(seq 1 60); do
    NIRI_SOCK="$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -oP '^niri\.\K[^.]+' | head -1 || true)"
    [ -n "$NIRI_SOCK" ] && break
    kill -0 "$HOST_PID" 2>/dev/null || break
    sleep 0.5
done
[ -n "$NIRI_SOCK" ] || { echo "niri socket 未出现"; tail -30 "$LOG_DIR/sway.log" >&2; exit 1; }
export WAYLAND_DISPLAY="$NIRI_SOCK"
echo ">> niri 就绪：$NIRI_SOCK"

# —— 采样器（先起，覆盖 qs 启动全程）：comm ∈ {qs,quickshell} 的 VmRSS/UTC ——
python3 - > "$OUT_DIR/card-perf.csv" <<'PY' &
import time, csv, sys, signal
from pathlib import Path

def targets():
    out = []
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            comm = Path(f"/proc/{p.name}/comm").read_text().strip()
        except OSError:
            continue
        if comm in ("qs", "quickshell"):
            out.append((int(p.name), comm))
    return out

def rss_kb(pid):
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    except OSError:
        pass
    return None

def ticks(pid):
    try:
        data = Path(f"/proc/{pid}/stat").read_text()
        tail = data[data.rfind(")") + 2:].split()
        return int(tail[11]) + int(tail[12])
    except (OSError, ValueError, IndexError):
        return None

w = csv.writer(sys.stdout, lineterminator="\n")
w.writerow(["t_ms", "pid", "comm", "rss_kb", "cpu_ticks"])
t0 = time.monotonic()
stop = False
def on_term(sig, frm):
    global stop
    stop = True
signal.signal(signal.SIGTERM, on_term)
while not stop:
    for pid, comm in targets():
        r, c = rss_kb(pid), ticks(pid)
        if r is not None:
            w.writerow([int((time.monotonic() - t0) * 1000), pid, comm, r, c])
    sys.stdout.flush()
    time.sleep(0.2)
PY
SAMPLER_PID=$!

# —— feeder（服务端先 listen）→ 卡片 ——
rm -f "$AIINPUT_CARD_SOCK"
# feed.py 不读 env：socket 路径必须 -s 显式传（与卡片的 AIINPUT_CARD_SOCK 对齐）
python3 /card/tools/feed.py -s "$AIINPUT_CARD_SOCK" \
    /lab/spec/events/voice-full.jsonl /lab/spec/events/pinyin-flow.jsonl \
    > "$LOG_DIR/feed.log" 2>&1 &
FEED_PID=$!
# 服务端 listen 就绪（socket 文件出现）再起卡片，避免首连竞态
for _ in $(seq 1 50); do
    [ -S "$AIINPUT_CARD_SOCK" ] && break
    kill -0 "$FEED_PID" 2>/dev/null || break
    sleep 0.1
done

qs -p /card > "$LOG_DIR/card.log" 2>&1 &
CARD_PID=$!

# 等 feeder 回放完退出（含 TAIL_WAIT），上限 120s 防挂
for _ in $(seq 1 240); do
    kill -0 "$FEED_PID" 2>/dev/null || break
    sleep 0.5
done
kill -0 "$FEED_PID" 2>/dev/null && { echo "!! feeder 超时未退出"; kill "$FEED_PID"; }

# 3s 稳态采样后收尾
sleep 3
kill -TERM "$SAMPLER_PID" 2>/dev/null || true
wait "$SAMPLER_PID" 2>/dev/null || true
kill "$CARD_PID" 2>/dev/null || true
kill "$HOST_PID" 2>/dev/null || true

echo ">> card-bench 完成"
echo "   card-perf.csv 行数: $(wc -l < "$OUT_DIR/card-perf.csv")"
tail -5 "$LOG_DIR/feed.log" || true
