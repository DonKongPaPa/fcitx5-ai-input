#!/usr/bin/env bash
# KDE 环境容器内编排：kwin_wayland --virtual 无头运行
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

DURATION="${DURATION:-10}"
MODE="${MODE:-sleep}"

# 1. kwin 无头（虚拟输出）
ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | sort >"$LOG_DIR/sockets.before" || true
kwin_wayland --virtual --no-lockscreen --no-global-shortcuts \
    >"$LOG_DIR/kwin.log" 2>&1 &
KWIN_PID=$!

KWIN_SOCK=""
for _ in $(seq 1 60); do
    ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | sort >"$LOG_DIR/sockets.now" || true
    KWIN_SOCK="$(comm -13 "$LOG_DIR/sockets.before" "$LOG_DIR/sockets.now" | head -1 || true)"
    [ -n "$KWIN_SOCK" ] && break
    sleep 0.5
done
[ -n "$KWIN_SOCK" ] || { echo "kwin socket 未出现"; cat "$LOG_DIR/kwin.log" >&2; exit 1; }
export WAYLAND_DISPLAY="$KWIN_SOCK"
echo "kwin 就绪：socket=$KWIN_SOCK"

# 2. 公共栈
start_audio
setup_virtual_mic >/dev/null
start_fcitx5

# 3. 录屏：gpu-screen-recorder（portal/pipewire，KDE 下可用；失败时看日志换 Spectacle）
gpu-screen-recorder -w screen -f 30 -a default \
    -o "$OUT_DIR/recording.mp4" >"$LOG_DIR/recorder.log" 2>&1 &
REC_PID=$!
sleep 2

# 4. 测试动作（M2：仅验证）
echo "环境验证运行 ${DURATION}s ……"
if [ "$MODE" = "shell" ]; then
    exec bash
fi
sleep "$DURATION"

# 5. 收尾
kill -INT "$REC_PID" 2>/dev/null || true
sleep 2
kill "$KWIN_PID" 2>/dev/null || true
cleanup_all

ls -la "$OUT_DIR"
echo "kde 环境验证完成"
