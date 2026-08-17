#!/usr/bin/env bash
# niri 环境容器内编排：cage(wlroots headless, 60Hz 帧时钟) 托管 niri → wf-recorder 录屏
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

DURATION="${DURATION:-10}"
MODE="${MODE:-sleep}"   # M2 验证用 sleep；M3+ 换成 case 驱动

# 1. cage 无头托管 niri（wlroots headless 有真实帧时钟；weston no-op 会卡死渲染）
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER_ALLOW_SOFTWARE=1 \
    cage -d -s niri >"$LOG_DIR/cage.log" 2>&1 &
CAGE_PID=$!

NIRI_SOCK=""
for _ in $(seq 1 60); do
    # niri 的 IPC socket 文件名形如 niri.wayland-N.P.sock，直接标明了它的 wayland socket
    NIRI_SOCK="$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -oP '^niri\.\K[^.]+' | head -1 || true)"
    [ -n "$NIRI_SOCK" ] && break
    sleep 0.5
done
[ -n "$NIRI_SOCK" ] || { echo "niri socket 未出现"; cat "$LOG_DIR/cage.log" >&2; exit 1; }
export WAYLAND_DISPLAY="$NIRI_SOCK"
# 录屏对着 cage（另一个 socket）：嵌套 niri 的 screencopy 不出帧，
# cage(wlroots) 的 screencopy 正常，画面内容即 niri 的输出
export CAGE_SOCK="$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | grep -v "^$NIRI_SOCK$" | head -1)"
echo "niri 就绪：socket=$NIRI_SOCK（应用） / cage=$CAGE_SOCK（录屏）"

# 2. 公共栈（音频/虚拟麦克风/fcitx5）；ENABLE_STACK=0 时跳过（M2 仅验证合成器+录屏）
if [ "${ENABLE_STACK:-1}" = "1" ]; then
    start_audio
    setup_virtual_mic >/dev/null
    start_fcitx5
fi

# 3. 动画窗口：保持持续重绘（niri 按需渲染，无变化时 screencopy 无帧）
#    MODE=case 时由 case-driver 启动 testapp（自带重绘定时器）
if [ "$MODE" != "case" ]; then
    weston-flower >"$LOG_DIR/flower.log" 2>&1 &
    FLOWER_PID=$!
    sleep 1
fi

# 3.5 用例驱动模式：交给 case-driver（自管录屏/触发/采集）
if [ "$MODE" = "case" ]; then
    bash "$SCRIPT_DIR/case-driver.sh"
    kill "$CAGE_PID" 2>/dev/null || true
    cleanup_all
    echo "niri 用例执行完成"
    exit 0
fi

# 4. 录屏（对着 cage 的 wlr-screencopy；通过 WAYLAND_DISPLAY 指定显示）
WAYLAND_DISPLAY="$CAGE_SOCK" wf-recorder --no-dmabuf --codec libx264 \
    -f "$OUT_DIR/recording.mp4" >"$LOG_DIR/wf-recorder.log" 2>&1 &
REC_PID=$!
sleep 1

# 5. 测试动作（M2：仅验证画面；M3+ 接入用例驱动）
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
kill "$FLOWER_PID" "$CAGE_PID" 2>/dev/null || true
cleanup_all

ls -la "$OUT_DIR"
echo "niri 环境验证完成"
