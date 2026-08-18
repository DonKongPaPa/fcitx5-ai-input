#!/usr/bin/env bash
# F2 状态机端到端验证（niri 容器内，root 安装后以 testuser 跑会话）
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx LIBGL_ALWAYS_SOFTWARE=1
export VI_LOG=/tmp/f2.log

call() { gdbus call --session --dest org.fcitx.Fcitx5 --object-path /org/fcitx/VoiceInput \
    --method org.fcitx.VoiceInput.Test."$1" "${@:2}" 2>&1; }

WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER_ALLOW_SOFTWARE=1 \
    cage -d -s niri >/tmp/cage.log 2>&1 &
for i in $(seq 1 30); do [ -S "$XDG_RUNTIME_DIR"/niri.*.sock ] 2>/dev/null && break
    sleep 0.5; done
niri_sock=$(ls "$XDG_RUNTIME_DIR" | grep -oP '^niri\.\K[^.]+' | head -1)
export WAYLAND_DISPLAY=$niri_sock
echo "== niri: $niri_sock"

fcitx5 -d --replace >/tmp/fcitx5.log 2>&1
sleep 3

export TEST_RESULT_FILE=/tmp/result.jsonl; rm -f $TEST_RESULT_FILE
/opt/dist/bin/testapp-gtk >/tmp/app.log 2>&1 &
sleep 3
echo "== testapp: $(head -c 120 $TEST_RESULT_FILE 2>/dev/null)"

echo; echo "===== 场景1: HoldRelease 模式（默认）====="
call SimulateKey Control_R true
sleep 0.1
echo "按下后: $(call State)"
sleep 1.2
echo "超阈值后:   $(call State)  ← 应为 recording"
sleep 3
call SimulateKey Control_R false >/dev/null
sleep 0.3
echo "松开后:     $(call State)  ← 应为 candidates"
echo "候选: $(call Candidates)"
call SimulateKey 1 true >/dev/null
sleep 0.5
echo "选1后落点: $(tail -1 $TEST_RESULT_FILE)"
echo "状态: $(call State)"

echo; echo "===== 场景2: 未到阈值松开（不触发）====="
call SimulateKey Control_R true >/dev/null
sleep 0.05
call SimulateKey Control_R false >/dev/null
sleep 0.3
echo "结果: $(call State)  ← 应为 idle（未进 recording）"

echo; echo "===== 场景3: Toggle 模式 ====="
mkdir -p ~/.config/fcitx5/conf
printf 'TriggerMode=Toggle\n' > ~/.config/fcitx5/conf/voiceinput.config
call Reload 2>/dev/null || true
# 触发 reload：通过修改文件后重启 fcitx5 太重；本场景先重启
fcitx5 -d --replace >/tmp/fcitx5-s3.log 2>&1; sleep 3
call SimulateKey Control_R true >/dev/null; sleep 0.5
call SimulateKey Control_R false >/dev/null; sleep 0.2
echo "起始松开后: $(call State)  ← 应仍 recording"
sleep 0.5
call SimulateKey Control_R true >/dev/null; sleep 0.3
echo "再按后:     $(call State)  ← 应为 candidates（LLM 开）"
call Escape true >/dev/null 2>&1 || call SimulateKey Escape true >/dev/null
sleep 0.3
echo "Esc 后:     $(call State)  ← 应为 idle"

echo; echo "===== LLM 关（直接上屏路径）====="
printf 'TriggerMode=HoldRelease\nLLMEnabled=False\n' > ~/.config/fcitx5/conf/voiceinput.config
fcitx5 -d --replace >/tmp/fcitx5-s4.log 2>&1; sleep 3
call SimulateKey Control_R true >/dev/null; sleep 0.6
call SimulateKey Control_R false >/dev/null; sleep 0.3
echo "状态: $(call State) ← 应为 result"
sleep 1.6
echo "超时后: $(call State)；落点: $(tail -1 $TEST_RESULT_FILE) ← idle+自动上屏"

echo; echo "===== 场景1 流式 partial（长窗口）====="
grep -ac "\[ui\] partial" /tmp/fcitx5.log | xargs echo "场景1 partial 数:"
grep -aoE "partial: .{0,30}" /tmp/fcitx5.log | head -4
echo "..."
grep -aoE "partial: .{0,30}" /tmp/fcitx5.log | tail -1
kill %1 %2 2>/dev/null
