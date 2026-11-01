#!/usr/bin/env bash
# qml-probe 容器内编排：sway(headless) 托管嵌套 niri → feeder 回放 jsonl → quickshell 探针
# 复刻 scripts/env/start-niri.sh 的无头栈（cage 720p 不可调，故用 sway 的
# output resolution；niri 官方不支持 headless 直跑），但不引入 fcitx5/录屏栈。
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
LOG_DIR="${LOG_DIR:-/tmp/logs}"
OUT_DIR="${OUT_DIR:-/tmp/out}"
mkdir -p "$LOG_DIR" "$OUT_DIR"

PROBE_SOCK="$XDG_RUNTIME_DIR/aiinput-probe.sock"
export AIINPUT_PROBE_SOCK="$PROBE_SOCK"
export LIBGL_ALWAYS_SOFTWARE=1
export QT_QUICK_BACKEND=software
export QT_QPA_PLATFORM=wayland

# 1. sway 无头宿主（wlroots headless 帧时钟）托管嵌套 niri；scale 固定 1.0
#    让「top+bottom 双锚 → h=1080-top-bottom」的 margins 断言算术干净
cat > "$LOG_DIR/niri-config.kdl" <<'KDL'
output "*" {
    scale 1.0
}
output "Winit" {
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
    # niri 的 IPC socket 文件名形如 niri.wayland-N.P.sock（同 start-niri.sh 的探测）
    NIRI_SOCK="$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -oP '^niri\.\K[^.]+' | head -1 || true)"
    [ -n "$NIRI_SOCK" ] && break
    kill -0 "$HOST_PID" 2>/dev/null || break
    sleep 0.5
done
[ -n "$NIRI_SOCK" ] || { echo "niri socket 未出现"; tail -30 "$LOG_DIR/sway.log" >&2; exit 1; }
export WAYLAND_DISPLAY="$NIRI_SOCK"
# niri IPC socket 全名带 PID 后缀（实测形如 niri.wayland-2.34.sock），须按通配取全名
NIRI_IPC="$(ls "$XDG_RUNTIME_DIR" | grep -E '^niri\..*\.sock$' | head -1 || true)"
export NIRI_SOCKET="$XDG_RUNTIME_DIR/$NIRI_IPC"
echo "niri 就绪：socket=$NIRI_SOCK"

# 2. feeder 先起（socket 就绪后卡片一次连接即成功，绕开重连时序）
rm -f "$PROBE_SOCK"
python3 -u /probe/feeder.py "$PROBE_SOCK" \
    /lab/spec/events/voice-full.jsonl \
    /lab/spec/events/pinyin-flow.jsonl \
    >"$LOG_DIR/feeder.log" 2>&1 &
FEEDER_PID=$!

# 3. quickshell 探针（对 niri 的 wayland socket；软件渲染）
qs -p /probe/probe-shell >"$LOG_DIR/quickshell.log" 2>&1 &
QS_PID=$!

# 4. 等 feeder 完成（= 回放+收尾窗结束），上限 120s
for _ in $(seq 1 120); do
    kill -0 "$FEEDER_PID" 2>/dev/null || break
    sleep 1
done
sleep 1  # 给 quickshell 留尾帧日志（MARGIN_AFTER 等）

# 5. niri 侧取证（尽力，不作为门控）：layer surface 列表 + 整窗截图
niri msg layers >"$LOG_DIR/niri-layers.txt" 2>"$LOG_DIR/niri-msg-err.txt" || true
SWAY_SOCK="$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | grep -v "^$NIRI_SOCK$" | head -1 || true)"
if [ -n "$SWAY_SOCK" ]; then
    WAYLAND_DISPLAY="$SWAY_SOCK" grim "$OUT_DIR/probe-screenshot.png" \
        >"$LOG_DIR/grim.log" 2>&1 || true
fi

# 6. 断言（python -I：不读 cwd 的任何植入文件）
set +e
python3 -I /probe/assert-results.py "$OUT_DIR" "$LOG_DIR"
RC=$?
set -e

# 7. 收尾
kill "$QS_PID" "$FEEDER_PID" "$HOST_PID" 2>/dev/null || true
wait 2>/dev/null || true
exit $RC
