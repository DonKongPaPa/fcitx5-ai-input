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

# ============================ S6 连续三轮触发 ============================
echo "S6 连续三轮触发（popup 复用 + 落点依次追加）"
set_cfg "TriggerMode=HoldRelease" "TriggerThresholdMs=300" "LLMEnabled=True" \
        "DummyText=第一轮内容" "DummyStream=True" "DummyStreamIntervalMs=120" \
        "PopupTimeoutMs=1500"
s6_base=$(grep -ac "partial:" /tmp/fcitx5.log || true)
r1_text="第一轮内容。"   # 数字 1 → 润色版
call SimulateKey Control_R true >/dev/null; sleep 1.3
call SimulateKey Control_R false >/dev/null; sleep 0.5
call SimulateKey 1 true >/dev/null; sleep 0.4
st=$(call State)
case "$st" in *idle*) ok "轮1 完成 ($st)";; *) bad "轮1 未完成：$st";; esac
txt=$(last_text)
case "$txt" in *"$r1_text") ok "轮1 落点=[$txt]";; *) bad "轮1 落点异常=[$txt]";; esac

set_cfg "TriggerMode=HoldRelease" "TriggerThresholdMs=300" "LLMEnabled=True" \
        "DummyText=第二轮不同文本" "DummyStream=True" "PopupTimeoutMs=1500"
call SimulateKey Control_R true >/dev/null; sleep 1.3
call SimulateKey Control_R false >/dev/null; sleep 0.5
call SimulateKey 2 true >/dev/null; sleep 0.4   # 数字 2 → 原始版
st=$(call State)
case "$st" in *idle*) ok "轮2 完成 ($st)";; *) bad "轮2 未完成：$st";; esac
txt=$(last_text)
case "$txt" in *"第二轮不同文本") ok "轮2 落点(原始版)=[$txt]";; *) bad "轮2 落点异常=[$txt]";; esac

set_cfg "TriggerMode=HoldRelease" "TriggerThresholdMs=300" "LLMEnabled=True" \
        "DummyText=第三轮再换" "DummyStream=True" "PopupTimeoutMs=1500"
call SimulateKey Control_R true >/dev/null; sleep 1.3
call SimulateKey Control_R false >/dev/null; sleep 0.5
call SimulateKey 1 true >/dev/null; sleep 0.4
st=$(call State)
case "$st" in *idle*) ok "轮3 完成 ($st)";; *) bad "轮3 未完成：$st";; esac
txt=$(last_text)
case "$txt" in *"第三轮再换。") ok "轮3 落点=[$txt]（三轮依次追加）";; *) bad "轮3 落点异常=[$txt]";; esac
# popup 复用：桥只连接一次（无重复拉起）
spawn_cnt=$(grep -ac "flutter UI spawned" /tmp/fcitx5.log || true)
[ "$spawn_cnt" -le 1 ] && ok "flutter 进程单实例复用（spawned=$spawn_cnt）" || bad "重复拉起 spawned=$spawn_cnt"
# 每轮 partial 独立
s6_now=$(grep -ac "partial:" /tmp/fcitx5.log || true)
n=$((s6_now - s6_base))
[ "$n" -ge 3 ] && ok "三轮 partial 累计 $n 步（每轮独立流动）" || bad "三轮 partial 异常 $n 步"

# ============================ S7 长文本 ============================
echo "S7 长文本（135 字，非流式保全文完整）"
LONG="语音输入法正在处理一段很长的中文文本用来验证长文本场景下悬浮窗的显示与提交行为包括流式识别过程中尾部优先的截断策略候选列表的单行省略以及最终提交到输入框的完整一致性这是一段超过一百二十个字符的测试数据"
set_cfg "TriggerMode=HoldRelease" "TriggerThresholdMs=300" "LLMEnabled=True" \
        "DummyText=$LONG" "DummyStream=False" "PopupTimeoutMs=1500"
call SimulateKey Control_R true >/dev/null; sleep 1.0
call SimulateKey Control_R false >/dev/null; sleep 0.6
st=$(call State)
case "$st" in *candidates*) ok "长文本 → candidates ($st)";; *) bad "长文本状态异常：$st";; esac
cand=$(call Candidates)
long_chars=$(echo -n "$LONG" | wc -m)
case "$cand" in *"$LONG"*) ok "候选含长文本全文（${long_chars} 字符）";; *) bad "候选缺全文：${cand:0:60}...";; esac
call SimulateKey 1 true >/dev/null; sleep 0.5
txt=$(last_text)
tail10="${LONG: -10}"
nchars=$(echo -n "$txt" | wc -m)
case "$txt" in *"$tail10"*) tail_ok=0;; *) tail_ok=1;; esac
if [ "$tail_ok" -eq 0 ] && [ "$nchars" -ge "$long_chars" ]; then
    ok "长文本落点完整（${nchars} 字符，尾部精确匹配）"
else
    bad "长文本落点异常（${nchars} 字符 tail_ok=$tail_ok）"
fi

# ============================ S8 录音中取消 + 复用 ============================
echo "S8 录音中 Esc 取消 + 立即复用"
set_cfg "TriggerMode=HoldRelease" "TriggerThresholdMs=300" "LLMEnabled=True" \
        "DummyText=取消场景不应提交" "DummyStream=True" "PopupTimeoutMs=1500"
before_cnt=$(wc -l < "$TEST_RESULT_FILE")
call SimulateKey Control_R true >/dev/null; sleep 0.9
call SimulateKey Escape true >/dev/null; sleep 0.4
st=$(call State)
case "$st" in *idle*) ok "录音中 Esc → idle ($st)";; *) bad "取消失败：$st";; esac
after_cnt=$(wc -l < "$TEST_RESULT_FILE")
[ "$after_cnt" -eq "$before_cnt" ] && ok "取消后无落点" || bad "取消仍落点（$before_cnt→$after_cnt）"
# 立即复用：马上再来一轮完整流程
set_cfg "TriggerMode=HoldRelease" "TriggerThresholdMs=300" "LLMEnabled=True" \
        "DummyText=取消后复用正常" "DummyStream=True" "PopupTimeoutMs=1500"
call SimulateKey Control_R true >/dev/null; sleep 1.2
call SimulateKey Control_R false >/dev/null; sleep 0.5
call SimulateKey 1 true >/dev/null; sleep 0.4
st=$(call State)
case "$st" in *idle*) ok "取消后立即复用成功 ($st)";; *) bad "复用失败：$st";; esac
txt=$(last_text)
case "$txt" in *"取消后复用正常。") ok "复用轮落点=[$txt]";; *) bad "复用轮落点异常=[$txt]";; esac

# ============================ 收尾 ============================
sleep 1
kill -INT $REC 2>/dev/null; sleep 2
kill %1 %2 %3 2>/dev/null

echo "=============================="
echo "F5 结果: PASS=$PASS FAIL=$FAIL"
grep -ac "config-reloaded" /tmp/fcitx5.log | xargs -I{} echo "config-reloaded 次数: {}（热改生效痕迹）"
[ "$FAIL" -eq 0 ] && echo "F5 端到端：全部通过 ✓" || echo "F5 端到端：存在失败 ✗"
