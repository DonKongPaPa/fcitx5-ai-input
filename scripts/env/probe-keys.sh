#!/usr/bin/env bash
# 最小换键 probe：完整 niri 栈下测 TriggerKeys 文件切换后各键名是否触发
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export LIBGL_ALWAYS_SOFTWARE=1
unset GTK_IM_MODULE QT_IM_MODULE

WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER_ALLOW_SOFTWARE=1 \
    cage -d -s niri >/tmp/cage.log 2>&1 &
niri_sock=""
for i in $(seq 1 30); do
    niri_sock=$(ls "$XDG_RUNTIME_DIR" | grep -oP '^niri\.\K[^.]+' | head -1)
    [ -n "$niri_sock" ] && break; sleep 0.5
done
export WAYLAND_DISPLAY=$niri_sock

fcitx5 -d --replace --disable=classicui >/tmp/f.log 2>&1
call() { gdbus call --session --dest org.fcitx.Fcitx5 --object-path /org/fcitx/VoiceInput \
    --method org.fcitx.VoiceInput.Test."$1" "${@:2}" 2>&1; }
for i in $(seq 1 40); do call State >/dev/null 2>&1 && break; sleep 0.5; done
sleep 1

CONF="$HOME/.config/fcitx5/conf/voiceinput.config"
mkdir -p "$(dirname "$CONF")"
for K in F9 Pause; do
    printf 'TriggerKeys=%s\nAsrEngine=Dummy\nDummyText=%s\nDummyStream=False\nLLMEnabled=True\nTriggerThresholdMs=300\n' \
        "$K" "$K" > "$CONF"
    gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.ReloadAddonConfig "voiceinput" >/dev/null 2>&1
    sleep 0.6
    grep -q "^TriggerKeys=$K$" "$CONF" && echo "$K: 文件已写" || echo "$K: 文件异常"
    call SimulateKey "$K" true >/dev/null; sleep 1.0
    echo "$K 按下 1s → $(call State)"
    call SimulateKey "$K" false >/dev/null; sleep 0.5
    echo "$K 松开 → $(call State)"
    call SimulateKey Escape true >/dev/null; sleep 0.3
    grep -a "pressing\|recording-start" /tmp/f.log | tail -2
done
cp /tmp/f.log /out/f.log 2>/dev/null || true
kill %1 2>/dev/null
