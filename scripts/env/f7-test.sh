#!/usr/bin/env bash
# F7 部署档 × configtool 测试（容器侧）：
#   S1 configtool 真实保存链路（D-Bus SetConfig，即 GUI 点保存的路径）
#   S2 configtool GUI 冒烟（窗口出现）
#   S3 ASR GPU 档核心场景（FUNASR_URL_GPU）
#   S4 ASR CPU 档核心场景（FUNASR_URL_CPU，int8 量化，超时放宽）
# 宿主编排：scripts/run-f7.sh（起两档服务/采样/汇总）
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export LIBGL_ALWAYS_SOFTWARE=1
export TEST_RESULT_FILE=/tmp/app-events.jsonl
unset GTK_IM_MODULE QT_IM_MODULE
: > "$TEST_RESULT_FILE"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

call() { gdbus call --session --dest org.fcitx.Fcitx5 --object-path /org/fcitx/VoiceInput \
    --method org.fcitx.VoiceInput.Test."$1" "${@:2}" 2>&1; }
ctrl() { gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
    --method org.fcitx.Fcitx.Controller1."$1" "${@:2}" 2>&1; }

FUNASR_URL_GPU="${FUNASR_URL_GPU:-ws://host.containers.internal:10095}"
FUNASR_URL_CPU="${FUNASR_URL_CPU:-ws://host.containers.internal:10096}"

# —— 环境（同 f6：cage/niri + weston + fcitx5 + testapp + 音频栈）——
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

LOG_DIR=/tmp/logs; mkdir -p "$LOG_DIR"
# shellcheck disable=SC1091
source /scripts/env/common.sh >/dev/null 2>&1 || true
unset GTK_IM_MODULE QT_IM_MODULE
start_audio >/dev/null 2>&1 || true
defsrc=""
for i in $(seq 1 15); do
    setup_virtual_mic >/dev/null 2>&1 || true
    defsrc="$(pactl get-default-source 2>/dev/null || true)"
    case "$defsrc" in *vi_mic*) break;; esac
    sleep 1
done
echo "音频栈: $defsrc"

export VOICEINPUT_UI_DISPLAY=flutter-hd
fcitx5 -d --replace --disable=classicui >/tmp/fcitx5.log 2>&1
/opt/dist/bin/testapp-gtk >/tmp/app.log 2>&1 &
for i in $(seq 1 40); do call State >/dev/null 2>&1 && break; sleep 0.5; done
sleep 2.5

date +%s.%N > /tmp/t-recorder
WAYLAND_DISPLAY=$cage_sock wf-recorder --no-dmabuf --codec libx264 -f /tmp/f7.mp4 >/tmp/wf.log 2>&1 &
REC=$!
sleep 1

last_text() { tail -1 "$TEST_RESULT_FILE" 2>/dev/null | grep -oP '"text":"\K[^"]*'; }
wait_state() {
    for _ in $(seq 1 $(( ${2:-10} * 2 ))); do
        case "$(call State)" in *"$1"*) return 0;; esac
        sleep 0.5
    done
    return 1
}
CONF_FILE="$HOME/.config/fcitx5/conf/voiceinput.config"

# ============================ S1 configtool 保存链路 ============================
echo "S1 configtool 保存链路（D-Bus SetConfig）"
gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
    --method org.fcitx.Fcitx.Controller1.SetConfig \
    "fcitx://config/addon/voiceinput" "<{'TriggerThresholdMs': <'800'>}>" >/tmp/setcfg.out 2>&1 || true
sleep 0.5
if grep -aq "config-saved-via-configtool" /tmp/fcitx5.log; then
    ok "setConfig 回调触发（基类 no-op bug 已修复）"
else
    bad "setConfig 未触发: $(head -2 /tmp/setcfg.out)"
fi
grep -q "^TriggerThresholdMs=800$" "$CONF_FILE" 2>/dev/null \
    && ok "配置已落盘（TriggerThresholdMs=800）" \
    || bad "未落盘（$(cat "$CONF_FILE" 2>/dev/null | head -2)）"
# 行为立变：500ms 短按（<800）不触发
call SimulateKey Control_R true >/dev/null; sleep 0.5
call SimulateKey Control_R false >/dev/null; sleep 0.3
case "$(call State)" in *idle*) ok "800ms 阈值下 500ms 短按不触发";; *) bad "阈值未生效: $(call State)";; esac
# 行为恢复：SetConfig 回 300 → 1.2s 触发录音
gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
    --method org.fcitx.Fcitx.Controller1.SetConfig \
    "fcitx://config/addon/voiceinput" "<{'TriggerThresholdMs': <'300'>}>" >/dev/null 2>&1 || true
sleep 0.5
call SimulateKey Control_R true >/dev/null; sleep 1.2
case "$(call State)" in *recording*) ok "恢复 300 后 1.2s 触发录音";; *) bad "恢复失败: $(call State)";; esac
call SimulateKey Escape true >/dev/null; sleep 0.4
# GetConfig 往返
gc=$(ctrl GetConfig '"fcitx://config/addon/voiceinput"' 2>&1)
case "$gc" in
*TriggerKeys*|*TriggerMode*) ok "GetConfig 含触发配置字段";;
*) bad "GetConfig 异常: ${gc:0:80}";;
esac
case "$gc" in *AsrEngine*) ok "GetConfig 含引擎字段";; *) bad "GetConfig 缺 AsrEngine";; esac

# ============================ S2 configtool GUI 冒烟 ============================
echo "S2 configtool GUI 冒烟"
fcitx5-configtool >/tmp/configtool.log 2>&1 &
CT_PID=$!
sleep 4
if kill -0 $CT_PID 2>/dev/null; then
    ok "fcitx5-configtool 进程存活"
else
    bad "configtool 退出: $(tail -2 /tmp/configtool.log)"
fi
NIRI_IPC="$XDG_RUNTIME_DIR/$(ls "$XDG_RUNTIME_DIR" | grep '^niri\.' | head -1)"
wins=$(NIRI_SOCKET="$NIRI_IPC" niri msg windows 2>/dev/null | grep -ci "config" || true)
[ "$wins" -ge 1 ] && ok "configtool 窗口已出现（niri 窗口列表）" || bad "未见窗口（niri msg: $(NIRI_SOCKET="$NIRI_IPC" niri msg windows 2>&1 | head -3)）"
sleep 2   # 录屏留证
kill $CT_PID 2>/dev/null

# ============================ S3/S4 ASR 部署档核心场景 ============================
asr_core() {  # $1=url $2=tag $3=超时秒
    local url="$1" tag="$2" tmo="$3"
    mkdir -p "$HOME/.config/fcitx5/conf"
    printf '%s\n' "AsrEngine=FunASR" "FunASRUrl=$url" "FunASRLanguage=中文" \
            "TriggerMode=HoldRelease" "TriggerThresholdMs=300" "LLMEnabled=True" \
            "PopupTimeoutMs=3000" > "$CONF_FILE"
    ctrl ReloadAddonConfig '"voiceinput"' >/dev/null; sleep 0.4
    local base; base="$(grep -ac "partial:" /tmp/fcitx5.log || true)"
    local t0; t0=$(date +%s.%N)
    call SimulateKey Control_R true >/dev/null; sleep 0.6
    pw-play --target vi_mic /samples/中文测试-16k.wav >/dev/null 2>&1 &
    sleep 8
    call SimulateKey Control_R false >/dev/null
    if wait_state candidates "$tmo"; then ok "[$tag] → candidates"; else bad "[$tag] 未到: $(call State)"; return; fi
    local t1; t1=$(date +%s.%N)
    local n; n=$(( "$(grep -ac "partial:" /tmp/fcitx5.log || true)" - base ))
    [ "$n" -ge 2 ] && ok "[$tag] 流式 partial ${n} 条" || bad "[$tag] partial ${n} 条"
    local cand; cand=$(call Candidates)
    case "$cand" in *"这是一段语音测试"*) ok "[$tag] 识别文本正确";; *) bad "[$tag] 候选: $cand";; esac
    sleep 1.5
    call SimulateKey 1 true >/dev/null; sleep 0.6
    local txt; txt=$(last_text)
    case "$txt" in *"这是一段语音测试"*) ok "[$tag] 落点 ✓";; *) bad "[$tag] 落点: $txt";; esac
    echo "  [$tag] 会话耗时 $(python3 -c "print(f'{$t1-$t0:.1f}')")s（press→candidates）"
}

echo "S3 ASR GPU 档（$FUNASR_URL_GPU）"
asr_core "$FUNASR_URL_GPU" GPU 20
echo "S4 ASR CPU 档 int8（$FUNASR_URL_CPU，超时放宽 60s）"
asr_core "$FUNASR_URL_CPU" CPU 60

sleep 1
kill -INT $REC 2>/dev/null; sleep 2
kill %1 %2 %3 2>/dev/null
echo "=============================="
echo "F7 结果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "F7 部署档×configtool：全部通过 ✓" || echo "F7：存在失败 ✗"
