#!/usr/bin/env bash
# GNOME 环境容器内编排：sway(wlroots headless) 托管 gnome-shell 嵌套运行 → wf-recorder 录屏
#（mutter 嵌套模式：设置 WAYLAND_DISPLAY 后 gnome-shell --wayland 自动嵌套）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

DURATION="${DURATION:-10}"
MODE="${MODE:-sleep}"

# 1. sway 无头宿主，exec 拉起嵌套 gnome-shell
cat >"$LOG_DIR/sway-config" <<EOF
output HEADLESS-1 resolution 1280x800
exec env WLR_BACKENDS=headless sh -c 'WAYLAND_DISPLAY=\$(ls \$XDG_RUNTIME_DIR | grep -E "^wayland-[0-9]+\$" | sort | head -1) exec gnome-shell --wayland --wayland-display gnome-hd --no-x11'
EOF
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER_ALLOW_SOFTWARE=1 \
    sway -c "$LOG_DIR/sway-config" >"$LOG_DIR/sway.log" 2>&1 &
HOST_PID=$!

GNOME_SOCK=""
for _ in $(seq 1 90); do
    [ -S "$XDG_RUNTIME_DIR/gnome-hd" ] && GNOME_SOCK=gnome-hd && break
    kill -0 "$HOST_PID" 2>/dev/null || break
    sleep 0.5
done
# socket 可能残留于崩溃后，多等 3 秒确认 gnome-shell 进程存活
if [ -n "$GNOME_SOCK" ]; then
    sleep 3
    pgrep -x gnome-shell >/dev/null || GNOME_SOCK=""
fi

if [ -z "$GNOME_SOCK" ]; then
    # gnome-shell 嵌套需要 logind session（容器内没有）→ 回退裸 mutter 嵌套
    echo "gnome-shell 嵌套失败，回退裸 mutter 嵌套（sway 客户端）："
    tail -15 "$LOG_DIR/sway.log" >&2 || true
    WAYLAND_DISPLAY="$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | sort | head -1)" \
        mutter --wayland --wayland-display gnome-hd >"$LOG_DIR/mutter.log" 2>&1 &
    MUTTER_PID=$!
    for _ in $(seq 1 90); do
        [ -S "$XDG_RUNTIME_DIR/gnome-hd" ] && GNOME_SOCK=gnome-hd && break
        kill -0 "$MUTTER_PID" 2>/dev/null || break
        sleep 0.5
    done
    if [ -z "$GNOME_SOCK" ]; then
        # 最后回退：mutter 独立无头（无 sway 宿主 → 无录屏）
        echo "mutter 嵌套失败，回退 mutter headless（无录屏）："
        tail -10 "$LOG_DIR/mutter.log" >&2 || true
        mutter --wayland --headless >"$LOG_DIR/mutter-headless.log" 2>&1 &
        for _ in $(seq 1 90); do
            [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && GNOME_SOCK=wayland-1 && break
            sleep 0.5
        done
    fi
fi
[ -n "$GNOME_SOCK" ] || { echo "gnome/mutter socket 均未出现"; exit 1; }
export WAYLAND_DISPLAY="$GNOME_SOCK"
# sway 的 wayland socket（录屏用；case-driver 依赖 CAGE_SOCK 变量名）
export CAGE_SOCK="$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | sort | head -1)"
echo "gnome 就绪：socket=$GNOME_SOCK（应用） / sway=$CAGE_SOCK（录屏）"

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
    echo "gnome 用例执行完成"
    exit 0
fi

# 4. 录屏（对着 sway 的 wlr-screencopy）
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
echo "gnome 环境验证完成"
