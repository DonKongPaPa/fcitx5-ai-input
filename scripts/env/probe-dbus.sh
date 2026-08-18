#!/usr/bin/env bash
set -u
export XDG_RUNTIME_DIR=/run/user/1000
fcitx5 -d >/tmp/fcitx5-probe.log 2>&1
sleep 2
mkdir -p "$HOME/.config/fcitx5/conf"
printf '%s\n' "TriggerThresholdMs=555" > "$HOME/.config/fcitx5/conf/voiceinput.config"
gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
    --method org.fcitx.Fcitx.Controller1.ReloadAddonConfig "voiceinput"
sleep 0.3
echo "config-reloaded 次数: $(grep -ac config-reloaded /tmp/fcitx5-probe.log)"
grep -a "ThresholdMs=555\|trigger" /tmp/fcitx5-probe.log | head -2
