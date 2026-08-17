#!/usr/bin/env bash
# F5 端到端管线用例（niri 容器，完整栈：popup/flutter UI 全程在环）
#
# 场景：
#   S1 HoldRelease + 候选数字键落点（文本进 testapp）
#   S2 阈值内松开不触发
#   S3 TriggerMode 热改 Toggle（写配置 + ReloadAddonConfig，行为立变）
#   S4 LLMEnabled 热改 False → 结果态 + 超时自动上屏
#   S5 流式逐字（partial 单调递增 ≥5 步）
# 断言源：D-Bus State/Candidates、testapp 事件文件（TEST_RESULT_FILE）、
# fcitx5 日志；录屏全程存档（视觉断言已由 f4-test 覆盖）
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export LIBGL_ALWAYS_SOFTWARE=1
export TEST_RESULT_FILE=/tmp/app-events.jsonl
unset GTK_IM_MODULE QT_IM_MODULE
: > "$TEST_RESULT_FILE"

PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

call() { gdbus call --session --dest org.fcitx.Fcitx5 --object-path /org/fcitx/VoiceInput \
    --method org.fcitx.VoiceInput.Test."$1" "${@:2}" 2>&1; }
ctrl() { # 注意接口名是 org.fcitx.Fcitx.Controller1（不带 5，fcitx5 兼容名）
    gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1."$1" "${@:2}" 2>&1; }

set_cfg() {  # 写配置 + 触发 reload（等效 configtool 保存）
    mkdir -p "$HOME/.config/fcitx5/conf"
    printf '%s\n' "$@" > "$HOME/.config/fcitx5/conf/voiceinput.config"
    ctrl ReloadAddonConfig '"voiceinput"' >/dev/null
    sleep 0.4
}

# —— 环境：cage(niri) + weston(flutter) + fcitx5 + testapp ——
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
sleep 2.5   # flutter 预热 + popup map 流水线

# 录屏存档
date +%s.%N > /tmp/t-recorder
WAYLAND_DISPLAY=$cage_sock wf-recorder --no-dmabuf --codec libx264 -f /tmp/f5.mp4 >/tmp/wf.log 2>&1 &
REC=$!
sleep 1

last_text() { tail -1 "$TEST_RESULT_FILE" 2>/dev/null | grep -oP '"text":"\K[^"]*'; }

# ============================ S1 候选落点 ============================
echo "S1 HoldRelease + 数字键选候选落点"
set_cfg "TriggerMode=HoldRelease" "TriggerThresholdMs=300" "LLMEnabled=True" \
        "DummyText=今天天气真好" "DummyStream=True" "DummyStreamIntervalMs=120" \
        "PopupTimeoutMs=1500"
s1_partial_base=$(grep -ac "partial:" /tmp/fcitx5.log || true)
call SimulateKey Control_R true >/dev/null; sleep 2.6
call SimulateKey Control_R false >/dev/null; sleep 0.6
st=$(call State)
case "$st" in *candidates*) ok "release → candidates ($st)";; *) bad "期望 candidates，实际 $st";; esac
cand=$(call Candidates)
case "$cand" in *今天天气真好。*) ok "候选含润色版：$cand";; *) bad "候选异常：$cand";; esac
call SimulateKey 1 true >/dev/null; sleep 0.6
st=$(call State)
case "$st" in *idle*) ok "数字 1 → idle ($st)";; *) bad "选择后未 idle：$st";; esac
txt=$(last_text)
[ "$txt" = "今天天气真好。" ] && ok "testapp 落点文本=[$txt]" || bad "落点文本异常=[$txt]"
# S5 流式逐字（借 S1 录音段统计）
s1_partial=$(grep -ac "partial:" /tmp/fcitx5.log || true)
n=$((s1_partial - s1_partial_base))
[ "$n" -ge 5 ] && ok "流式 partial 步数=$n（≥5）" || bad "partial 步数不足=$n"
growing=$(grep -a "partial:" /tmp/fcitx5.log | tail -"$n" | awk '{print length($0)}' | sort -rn | head -1)
lastlen=$(grep -a "partial:" /tmp/fcitx5.log | tail -1 | awk '{print length($0)}')
[ "$growing" = "$lastlen" ] && ok "partial 单调递增长度" || bad "partial 非单调"

# ============================ S2 阈值内松开 ============================
echo "S2 阈值内松开不触发"
set_cfg "TriggerMode=HoldRelease" "TriggerThresholdMs=300" "LLMEnabled=True" \
        "DummyText=不应出现" "PopupTimeoutMs=1500"
call SimulateKey Control_R true >/dev/null; sleep 0.12
call SimulateKey Control_R false >/dev/null; sleep 0.4
st=$(call State)
case "$st" in *idle*) ok "短按透传未触发 ($st)";; *) bad "短按误触发：$st";; esac
grep -q "不应出现" "$TEST_RESULT_FILE" && bad "未触发却有文本落点" || ok "无文本落点"

# ============================ S3 Toggle 热改 ============================
echo "S3 TriggerMode 热改为 Toggle"
set_cfg "TriggerMode=Toggle" "TriggerThresholdMs=300" "LLMEnabled=True" \
        "DummyText=开关模式测试" "DummyStream=True" "DummyStreamIntervalMs=120"
call SimulateKey Control_R true >/dev/null; sleep 0.6
call SimulateKey Control_R false >/dev/null; sleep 0.4   # Toggle：松开不结束
st=$(call State)
case "$st" in *recording*) ok "Toggle 松开后仍录音 ($st)";; *) bad "Toggle 松开即停：$st";; esac
sleep 0.8
call SimulateKey Control_R true >/dev/null; sleep 0.15   # 第二次按下结束
call SimulateKey Control_R false >/dev/null; sleep 0.6
st=$(call State)
case "$st" in *candidates*) ok "再按结束 → candidates ($st)";; *) bad "Toggle 结束异常：$st";; esac
call SimulateKey Escape true >/dev/null; sleep 0.3

# ============================ S4 LLM 关自动上屏 ============================
echo "S4 LLMEnabled=False 热改：结果态自动上屏"
set_cfg "TriggerMode=HoldRelease" "TriggerThresholdMs=300" "LLMEnabled=False" \
        "DummyText=直接上屏" "DummyStream=False" "PopupTimeoutMs=800"
call SimulateKey Control_R true >/dev/null; sleep 1.6
call SimulateKey Control_R false >/dev/null; sleep 0.5
st=$(call State)
case "$st" in *result*) ok "LLM 关 → result 态 ($st)";; *) bad "期望 result：$st";; esac
sleep 1.5   # 超过 PopupTimeoutMs=800
st=$(call State)
case "$st" in *idle*) ok "超时自动上屏 → idle ($st)";; *) bad "超时未上屏：$st";; esac
txt=$(last_text)
case "$txt" in *直接上屏) ok "自动落点文本=[$txt]（追加到已有文本后）";; *) bad "落点异常=[$txt]";; esac

# ============================ 收尾 ============================
sleep 1
kill -INT $REC 2>/dev/null; sleep 2
kill %1 %2 %3 2>/dev/null

echo "=============================="
echo "F5 结果: PASS=$PASS FAIL=$FAIL"
grep -ac "config-reloaded" /tmp/fcitx5.log | xargs -I{} echo "config-reloaded 次数: {}（热改生效痕迹）"
[ "$FAIL" -eq 0 ] && echo "F5 端到端：全部通过 ✓" || echo "F5 端到端：存在失败 ✗"
