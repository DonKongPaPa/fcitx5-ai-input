#!/usr/bin/env bash
# F4 诊断：长录音时间线——popup 首次可见时刻 vs 各事件时刻
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

weston --backend=headless-backend.so --socket=flutter-hd --width=400 --height=240 \
    --idle-time=0 >/tmp/weston-ui.log 2>&1 &
for i in $(seq 1 30); do [ -S "$XDG_RUNTIME_DIR/flutter-hd" ] && break; sleep 0.5; done

export VOICEINPUT_UI_DISPLAY=flutter-hd
fcitx5 -d --replace >/tmp/fcitx5.log 2>&1
/opt/dist/bin/testapp-gtk >/tmp/app.log 2>&1 &
for i in $(seq 1 40); do call State >/dev/null 2>&1 && break; sleep 0.5; done
sleep 2

date +%s.%N > /tmp/t-recorder
WAYLAND_DISPLAY=$cage_sock wf-recorder --no-dmabuf --codec libx264 -f /tmp/f4.mp4 >/tmp/wf.log 2>&1 &
REC=$!
sleep 1
date +%s.%N > /tmp/t-press
call SimulateKey Control_R true >/dev/null
sleep 9                     # 长录音
date +%s.%N > /tmp/t-release
call SimulateKey Control_R false >/dev/null
sleep 3                     # 候选期
date +%s.%N > /tmp/t-esc
call SimulateKey Escape true >/dev/null
sleep 0.5
kill -INT $REC 2>/dev/null
sleep 2
kill %1 %2 %3 2>/dev/null
for f in recorder press release esc; do echo "t-$f=$(cat /tmp/t-$f)"; done
grep -aE "\[ui\] (activated|pressing|recording-start|recording-stop|candidates|idle)|spawned|connected|first frame|frame #" /tmp/fcitx5.log | tail -10
