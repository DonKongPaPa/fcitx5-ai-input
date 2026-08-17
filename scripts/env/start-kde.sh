#!/usr/bin/env bash
# KDE 环境容器内编排：sway(wlroots headless) 托管 kwin 嵌套运行 → wf-recorder 录屏
#（cage 缺 zwp_pointer_constraints_v1，嵌套 kwin 直接退出；sway 协议齐全。
#  kwin --virtual 可无头直跑，但无 DRM 时录屏只能走 portal 授权，故用嵌套方案）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

DURATION="${DURATION:-10}"
MODE="${MODE:-sleep}"

# 1. sway 无头宿主，exec 拉起嵌套 kwin
#    sway 的 wayland socket 名不固定，exec 时动态探测传给 kwin。
#    KWIN_COMPOSE=Q：kwin 用 QtQuick 软件光栅渲染（容器里嵌套 GL 起不来：
#    "Failed to find a working output layer configuration"）
cat >"$LOG_DIR/sway-config" <<EOF
output HEADLESS-1 resolution 1280x800
exec env QT_FORCE_STDERR_LOGGING=1 KWIN_COMPOSE=Q sh -c 'WAYLAND_DISPLAY=\$(ls \$XDG_RUNTIME_DIR | grep -E "^wayland-[0-9]+\$" | sort | head -1) exec kwin_wayland --socket kwin-hd --output-count 1'
EOF
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER_ALLOW_SOFTWARE=1 \
    sway -c "$LOG_DIR/sway-config" >"$LOG_DIR/sway.log" 2>&1 &
HOST_PID=$!

KWIN_SOCK=""
for _ in $(seq 1 60); do
    [ -S "$XDG_RUNTIME_DIR/kwin-hd" ] && KWIN_SOCK=kwin-hd && break
    kill -0 "$HOST_PID" 2>/dev/null || break
    sleep 0.5
done
# socket 文件可能残留于 kwin 崩溃后，多等 3 秒确认 kwin 进程存活
if [ -n "$KWIN_SOCK" ]; then
    sleep 3
    pgrep -f "kwin_wayland --socket kwin-hd" >/dev/null || KWIN_SOCK=""
fi
[ -n "$KWIN_SOCK" ] || { echo "kwin socket 未出现或 kwin 已退出"; tail -30 "$LOG_DIR/sway.log" >&2; exit 1; }
export WAYLAND_DISPLAY="$KWIN_SOCK"
# sway 的 wayland socket（录屏用；case-driver 依赖 CAGE_SOCK 变量名）
export CAGE_SOCK="$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | sort | head -1)"
echo "kwin 就绪：socket=$KWIN_SOCK（应用） / sway=$CAGE_SOCK（录屏）"

# 2. 公共栈；ENABLE_STACK=0 时跳过
if [ "${ENABLE_STACK:-1}" = "1" ]; then
    start_audio
    setup_virtual_mic >/dev/null
    start_fcitx5
fi

# 3. 动画窗口（MODE=case 时由 case-driver 启动 testapp）
if [ "$MODE" != "case" ]; then
    weston-flower >"$LOG_DIR/flower.log" 2>&1 &
    FLOWER_PID=$!
    sleep 1
fi

# 3.5 用例驱动模式
if [ "$MODE" = "case" ]; then
    bash "$SCRIPT_DIR/case-driver.sh"
    kill "$HOST_PID" 2>/dev/null || true
    cleanup_all
    echo "kde 用例执行完成"
    exit 0
fi

# 4. 录屏（对着 sway 的 wlr-screencopy；sway 有真 GPU 渲染节点，可走 dmabuf）
WAYLAND_DISPLAY="$CAGE_SOCK" wf-recorder --no-dmabuf --codec libx264 \
    -f "$OUT_DIR/recording.mp4" >"$LOG_DIR/wf-recorder.log" 2>&1 &
REC_PID=$!
sleep 1

# 5. 测试动作
echo "环境验证运行 ${DURATION}s ……"
if [ "$MODE" = "shell" ]; then
    exec bash
fi
sleep "$DURATION"

# 6. 收尾（wf-recorder 需要 SIGINT 才能正确写完 mp4 尾部）
kill -INT "$REC_PID" 2>/dev/null || true
for _ in $(seq 1 20); do
    kill -0 "$REC_PID" 2>/dev/null || break
    sleep 0.5
done
kill "$REC_PID" 2>/dev/null || true
kill "$FLOWER_PID" "$HOST_PID" 2>/dev/null || true
cleanup_all

ls -la "$OUT_DIR"
echo "kde 环境验证完成"
