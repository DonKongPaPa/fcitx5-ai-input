#!/usr/bin/env bash
# KDE 环境手动调试脚本（容器内）：sway 无头宿主 + 嵌套 kwin + 录屏测试
set -u
export XDG_RUNTIME_DIR=/run/user/1000
mkdir -p /tmp/logs

cat >/tmp/sway-config <<'EOF'
output HEADLESS-1 resolution 1280x800
exec env QT_FORCE_STDERR_LOGGING=1 KWIN_COMPOSE=Q sh -c 'WAYLAND_DISPLAY=$(ls $XDG_RUNTIME_DIR | grep -E "^wayland-[0-9]+$" | sort | head -1) exec kwin_wayland --socket kwin-hd --output-count 1'
EOF

echo "== 启动 sway(headless) + 嵌套 kwin (KWIN_COMPOSE=Q 软件渲染)"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER_ALLOW_SOFTWARE=1 \
    sway -c /tmp/sway-config >/tmp/logs/sway.log 2>&1 &
for i in $(seq 1 40); do [ -S "$XDG_RUNTIME_DIR/kwin-hd" ] && break; sleep 0.5; done
sleep 4
echo "kwin alive=$(pgrep -fc kwin_wayland || echo 0)"

SWAY_SOCK="$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | sort | head -1)"
echo "sway socket=$SWAY_SOCK"

echo "== flower 跑在 kwin 下（damage 源）"
WAYLAND_DISPLAY=kwin-hd weston-flower >/dev/null 2>&1 &
sleep 2
echo "flower alive=$(pgrep -fc weston-flower || echo 0)"

echo "== wf-recorder 5 秒（对 sway，--no-dmabuf）"
WAYLAND_DISPLAY="$SWAY_SOCK" timeout -s INT -k 3 5 wf-recorder --no-dmabuf --codec libx264 \
    -f /tmp/r1.mp4 >/tmp/logs/wf1.log 2>&1 || true
tail -2 /tmp/logs/wf1.log
[ -f /tmp/r1.mp4 ] && { echo "录屏OK:"; ls -la /tmp/r1.mp4; } || echo "无录屏"

echo "== 渲染错误统计"
grep -cE "Rendering a layer failed|suitable render format" /tmp/logs/sway.log || true
echo "== sway.log 末尾"
tail -5 /tmp/logs/sway.log

kill %1 %2 2>/dev/null
exit 0
