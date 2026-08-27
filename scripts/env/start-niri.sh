#!/usr/bin/env bash
# niri 环境容器内编排：sway(wlroots headless) 托管 niri（1080p）→ wf-recorder 录屏
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

DURATION="${DURATION:-10}"
MODE="${MODE:-sleep}"   # M2 验证用 sleep；M3+ 换成 case 驱动

# 1. sway 无头宿主（wlroots headless 帧时钟）托管嵌套 niri
#    （cage 的 headless 输出 1280x720 硬编码不可调——1080p 需 sway 的
#    output resolution 配置；kde/gnome 环境同款托管。niri 官方不支持
#    headless 直跑。W3：HiDPI 由 NIRI_TEST_SCALE 控制整轮）
SCALE="${NIRI_TEST_SCALE:-2.0}"
mkdir -p "$LOG_DIR/niri-cfg"
# 坑：winit 后端的输出名（Smithay Winit Unknown）不吃 "*" 通配——
# 只写 "*" 时 scale 静默不生效（容器分数 scale 测试全程跑在 1.0 的
# 元凶）。两条都写
cat > "$LOG_DIR/niri-cfg/config.kdl" <<KDL
output "*" {
    scale $SCALE
}
output "Winit" {
    scale $SCALE
}
KDL
cat > "$LOG_DIR/sway-config" <<EOF
output HEADLESS-1 resolution 1920x1080
exec niri -c $LOG_DIR/niri-cfg/config.kdl
EOF

WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER_ALLOW_SOFTWARE=1 \
    sway -c "$LOG_DIR/sway-config" >"$LOG_DIR/sway.log" 2>&1 &
HOST_PID=$!

NIRI_SOCK=""
for _ in $(seq 1 60); do
    # niri 的 IPC socket 文件名形如 niri.wayland-N.P.sock，直接标明了它的 wayland socket
    NIRI_SOCK="$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -oP '^niri\.\K[^.]+' | head -1 || true)"
    [ -n "$NIRI_SOCK" ] && break
    kill -0 "$HOST_PID" 2>/dev/null || break
    sleep 0.5
done
[ -n "$NIRI_SOCK" ] || { echo "niri socket 未出现"; tail -30 "$LOG_DIR/sway.log" >&2; exit 1; }
export WAYLAND_DISPLAY="$NIRI_SOCK"
# 录屏对着 sway（另一个 socket）：嵌套 niri 的 screencopy 不出帧，
# sway(wlroots) 的 screencopy 正常，画面内容即 niri 的输出
export CAGE_SOCK="$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | grep -v "^$NIRI_SOCK$" | head -1)"
echo "niri 就绪：socket=$NIRI_SOCK（应用） / sway=$CAGE_SOCK（录屏，1080p）"

# 1.5 Xwayland 层（satellite→DISPLAY；X 组用例依赖，详见 common.sh）
start_xwayland_satellite

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

# 3.5 用例驱动模式：交给 case-driver（自管录屏/触发/采集）。
#     CASE_DRIVER 可覆盖（冒烟/一次性诊断脚本复用整条环境编排）
if [ "$MODE" = "case" ]; then
    bash "${CASE_DRIVER:-$SCRIPT_DIR/case-driver.sh}"
    kill "$HOST_PID" 2>/dev/null || true
    cleanup_all
    echo "niri 用例执行完成"
    exit 0
fi

# 3.6 定位测量模式：单场景双引擎（surface-test 根因分析工具）
if [ "$MODE" = "surface" ]; then
    bash "$SCRIPT_DIR/surface-driver.sh"
    kill "$HOST_PID" 2>/dev/null || true
    cleanup_all
    echo "surface 场景执行完成"
    exit 0
fi

# 4. 录屏（对着 sway 的 wlr-screencopy；通过 WAYLAND_DISPLAY 指定显示）
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
