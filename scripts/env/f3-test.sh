#!/usr/bin/env bash
# F3 验证：触发录音 → popup 显示在光标附近 → 录屏取证
# 注意：不设 GTK_IM_MODULE/QT_IM_MODULE —— 必须让 testapp 走原生
# text-input-v3（frontend=wayland_v2），waylandim 才会有 IM 激活和
# 光标矩形；设 =fcitx 会走 dbus 前端，popup 无法取 IM proxy
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export LIBGL_ALWAYS_SOFTWARE=1
unset GTK_IM_MODULE QT_IM_MODULE

call() { gdbus call --session --dest org.fcitx.Fcitx5 --object-path /org/fcitx/VoiceInput \
    --method org.fcitx.VoiceInput.Test."$1" "${@:2}" 2>&1; }

WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER_ALLOW_SOFTWARE=1 \
    cage -d -s niri >/tmp/cage.log 2>&1 &
niri_sock=""
for i in $(seq 1 30); do
    niri_sock=$(ls "$XDG_RUNTIME_DIR" | grep -oP '^niri\.\K[^.]+' | head -1)
    [ -n "$niri_sock" ] && break; sleep 0.5
done
export WAYLAND_DISPLAY=$niri_sock
cage_sock=$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | grep -v "^$niri_sock$" | head -1)

fcitx5 -d --replace >/tmp/fcitx5.log 2>&1
/opt/dist/bin/testapp-gtk >/tmp/app.log 2>&1 &
# 等 D-Bus 服务就绪
for i in $(seq 1 40); do
    call State >/dev/null 2>&1 && break; sleep 0.5
done
sleep 2

# 录屏
WAYLAND_DISPLAY=$cage_sock wf-recorder --no-dmabuf --codec libx264 -f /tmp/popup-test.mp4 >/tmp/wf.log 2>&1 &
REC=$!
sleep 1

# 触发 → popup 应显示 ~3 秒
echo "== 触发录音（HoldRelease 3s）"
call SimulateKey Control_R true >/dev/null
sleep 1
echo "state: $(call State)"
sleep 2
call SimulateKey Control_R false >/dev/null
sleep 0.5
echo "state: $(call State) (candidates, popup 应显示候选内容区)"
call SimulateKey Escape true >/dev/null
sleep 0.5
echo "state: $(call State) (idle, popup 应隐藏)"

kill -INT $REC 2>/dev/null
sleep 2
kill %1 %2 2>/dev/null
echo "=== VoicePopup 日志:"
grep -a "VoicePopup" /tmp/fcitx5.log
echo "=== fcitx5 存活: $(pgrep -x fcitx5 >/dev/null && echo yes || echo no)"
echo "=== 录屏: $(ls -la /tmp/popup-test.mp4 2>/dev/null | awk '{print $5}') bytes"
# 抽帧：录音中和候选两个时间点
ffmpeg -y -v error -i /tmp/popup-test.mp4 -vf "select=eq(n\,40)" -frames:v 1 /tmp/frame-recording.png 2>/dev/null
ffmpeg -y -v error -i /tmp/popup-test.mp4 -vf "select=eq(n\,110)" -frames:v 1 /tmp/frame-candidates.png 2>/dev/null
ls -la /tmp/frame-*.png 2>/dev/null
