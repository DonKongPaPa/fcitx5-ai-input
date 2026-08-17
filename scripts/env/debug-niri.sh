#!/usr/bin/env bash
# niri 环境手动调试脚本（容器内）
set -u
export XDG_RUNTIME_DIR=/run/user/1000
mkdir -p /tmp/logs

echo "== 启动 weston headless =="
weston --backend=headless-backend.so --socket=weston-hd --width 1280 --height 800 --idle-time=0 >/tmp/logs/weston.log 2>&1 &
for i in $(seq 1 20); do [ -S $XDG_RUNTIME_DIR/weston-hd ] && break; sleep 0.5; done
echo "weston socket: $(ls $XDG_RUNTIME_DIR/weston-hd 2>/dev/null || echo 缺失)"

echo "== 启动 niri nested =="
WAYLAND_DISPLAY=weston-hd niri >/tmp/logs/niri.log 2>&1 &
for i in $(seq 1 20); do
    sock=$(ls $XDG_RUNTIME_DIR | grep -E "^wayland-[0-9]+$" | grep -v weston | head -1)
    [ -n "$sock" ] && break
    sleep 0.5
done
export WAYLAND_DISPLAY="$sock"
echo "niri socket: $sock"

echo "== wf-recorder 4 秒测试 =="
timeout -s INT 4 wf-recorder --no-dmabuf --codec libx264 -f /tmp/r1.mp4 >/tmp/logs/wf1.log 2>&1
echo "wf-recorder exit=$?"
echo "--- wf-recorder 输出:"
cat /tmp/logs/wf1.log
if [ -f /tmp/r1.mp4 ]; then
    echo "--- 录屏文件:"
    ls -la /tmp/r1.mp4
else
    echo "--- 无录屏文件"
fi
echo "== 结束 =="
kill %1 %2 2>/dev/null
