#!/usr/bin/env bash
# niri 环境容器内编排：weston(headless) 宿主 → niri 嵌套运行 → wf-recorder 录屏
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

DURATION="${DURATION:-10}"
MODE="${MODE:-sleep}"   # M2 验证用 sleep；M3+ 换成 case 驱动

# 1. weston 无头后端作为宿主合成器
weston --backend=headless-backend.so --socket=weston-hd \
    --idle-time=0 >"$LOG_DIR/weston.log" 2>&1 &
WESTON_PID=$!
wait_wayland_socket weston-hd

# 2. niri 以嵌套客户端运行（记录启动前的 socket 集合，用于发现 niri 的新 socket）
ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | sort >"$LOG_DIR/sockets.before" || true
WAYLAND_DISPLAY=weston-hd niri >"$LOG_DIR/niri.log" 2>&1 &
NIRI_PID=$!

NIRI_SOCK=""
for _ in $(seq 1 60); do
    ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | sort >"$LOG_DIR/sockets.now" || true
    NIRI_SOCK="$(comm -13 "$LOG_DIR/sockets.before" "$LOG_DIR/sockets.now" | head -1 || true)"
    [ -n "$NIRI_SOCK" ] && break
    sleep 0.5
done
[ -n "$NIRI_SOCK" ] || { echo "niri socket 未出现"; cat "$LOG_DIR/niri.log" >&2; exit 1; }
export WAYLAND_DISPLAY="$NIRI_SOCK"
echo "niri 就绪：socket=$NIRI_SOCK"

# 3. 公共栈
start_audio
setup_virtual_mic >/dev/null
start_fcitx5

# 4. 录屏（对着 niri，wlr-screencopy；--no-dmabuf 规避 niri dmabuf v4 协议不匹配）
wf-recorder -d "$WAYLAND_DISPLAY" --no-dmabuf --codec libx264 \
    -f "$OUT_DIR/recording.mp4" >"$LOG_DIR/wf-recorder.log" 2>&1 &
REC_PID=$!
sleep 1

# 5. 测试动作（M2：仅验证画面；M3+ 接入 testapp 与用例驱动）
echo "环境验证运行 ${DURATION}s ……"
if [ "$MODE" = "shell" ]; then
    export -f wait_wayland_socket || true
    exec bash
fi
sleep "$DURATION"

# 6. 收尾
kill "$REC_PID" 2>/dev/null || true
sleep 1
kill "$NIRI_PID" "$WESTON_PID" 2>/dev/null || true
cleanup_all

ls -la "$OUT_DIR"
echo "niri 环境验证完成"
