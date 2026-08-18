#!/usr/bin/env bash
# F6 真实音频端到端（FunASR 接入）：
#   S1 中文 WS 流式（真实 partial 渐进 + 候选 + 落点）
#   S2 英语 WS（MLT 多语种）
#   S3 GGUF 本地档（非流式：录音期无 partial，最终文本正确）
#   S4 Dummy 回归（管线不受影响）
# 前提：宿主 funasr-serve 在跑（FUNASR_URL 指向 host.containers.internal）
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
set_cfg() {
    mkdir -p "$HOME/.config/fcitx5/conf"
    printf '%s\n' "$@" > "$HOME/.config/fcitx5/conf/voiceinput.config"
    ctrl ReloadAddonConfig '"voiceinput"' >/dev/null
    sleep 0.4
}

FUNASR_URL="${FUNASR_URL:-ws://host.containers.internal:10095}"

# —— 环境：cage(niri) + weston(flutter) + fcitx5 + testapp + 音频栈 ——
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

# 音频栈（pipewire + 虚拟麦 null-sink，默认 source 已指 vi_mic.monitor）
LOG_DIR=/tmp/logs; mkdir -p "$LOG_DIR"
# shellcheck disable=SC1091
source /scripts/env/common.sh >/dev/null 2>&1 || true
# common.sh 为 M 时代 Trigger 注入 export 了 GTK_IM_MODULE=fcitx——那会让
# testapp 走 dbus 前端、popup 拿不到 waylandim IM proxy（UI 不显示，F3 踩过）
unset GTK_IM_MODULE QT_IM_MODULE
start_audio >/dev/null 2>&1 || true
# 虚拟麦有启动竞态（pipewire 就绪前后 null-sink 加载可能失败）：重试到就绪
defsrc=""
for i in $(seq 1 15); do
    setup_virtual_mic >/dev/null 2>&1 || true
    defsrc="$(pactl get-default-source 2>/dev/null || true)"
    case "$defsrc" in *vi_mic*) break;; esac
    sleep 1
done
echo "音频栈就绪: default-source=$defsrc"
case "$defsrc" in
*vi_mic*) : ;;
*) echo "!! 虚拟麦未就绪（$defsrc），音频场景将失败" ;;
esac

export VOICEINPUT_UI_DISPLAY=flutter-hd
fcitx5 -d --replace >/tmp/fcitx5.log 2>&1
/opt/dist/bin/testapp-gtk >/tmp/app.log 2>&1 &
for i in $(seq 1 40); do call State >/dev/null 2>&1 && break; sleep 0.5; done
sleep 2.5

# 录屏存档
date +%s.%N > /tmp/t-recorder
WAYLAND_DISPLAY=$cage_sock wf-recorder --no-dmabuf --codec libx264 -f /tmp/f6.mp4 >/tmp/wf.log 2>&1 &
REC=$!
sleep 1

last_text() { tail -1 "$TEST_RESULT_FILE" 2>/dev/null | grep -oP '"text":"\K[^"]*'; }

record_and_play() {  # $1=wav $2=录音时长秒 $3=语言
    local partial_base
    partial_base="$(grep -ac "partial:" /tmp/fcitx5.log || true)"
    call SimulateKey Control_R true >/dev/null
    sleep 0.6                      # 等 capture 启动
    pw-play --target vi_mic "$1" >/dev/null 2>&1 &
    sleep "$2"
    call SimulateKey Control_R false >/dev/null
    echo "$partial_base"
}

wait_state() {  # $1=期望状态子串 $2=超时秒
    for _ in $(seq 1 $(( ${2:-10} * 2 ))); do
        case "$(call State)" in *"$1"*) return 0;; esac
        sleep 0.5
    done
    return 1
}

# ============================ S1 中文 WS 流式 ============================
echo "S1 中文 WS 流式识别"
set_cfg "AsrEngine=FunASR" "FunASRUrl=$FUNASR_URL" "FunASRLanguage=中文" \
        "TriggerMode=HoldRelease" "TriggerThresholdMs=300" "LLMEnabled=True" \
        "PopupTimeoutMs=3000"
base=$(record_and_play /samples/中文测试-16k.wav 8 中文)
if wait_state candidates 15; then ok "release → candidates"; else bad "未到 candidates: $(call State)"; fi
# 录音期真实 partial：含"你"的流式中间结果
n_partial=$(( "$(grep -ac "partial:" /tmp/fcitx5.log || true)" - base ))
if [ "$n_partial" -ge 2 ] && grep -a "partial:" /tmp/fcitx5.log | tail -"$n_partial" | grep -aq "你"; then
    ok "录音期真实中文 partial ${n_partial} 条"
else
    bad "partial 异常（${n_partial} 条）"
fi
cand=$(call Candidates)
case "$cand" in *"你好，这是一段语音测试"*) ok "候选含识别全文: ${cand:0:60}...";; *) bad "候选异常: $cand";; esac
call SimulateKey 1 true >/dev/null; sleep 0.6
txt=$(last_text)
case "$txt" in *"这是一段语音测试"*) ok "落点=[$txt]";; *) bad "落点异常=[$txt]";; esac
case "$(call State)" in *idle*) ok "回到 idle";; *) bad "状态残留: $(call State)";; esac

# ============================ S2 英语 WS ============================
echo "S2 英语 WS（MLT 多语种）"
set_cfg "AsrEngine=FunASR" "FunASRUrl=$FUNASR_URL" "FunASRLanguage=英文" \
        "LLMEnabled=True" "PopupTimeoutMs=3000"
base=$(record_and_play /samples/英语测试-16k.wav 8 英文)
if wait_state candidates 15; then ok "英语 → candidates"; else bad "英语未到 candidates: $(call State)"; fi
cand=$(call Candidates)
case "$cand" in *"English voice input test"*) ok "英语识别正确: ${cand:0:60}...";; *) bad "英语候选异常: $cand";; esac
call SimulateKey Escape true >/dev/null; sleep 0.4

# ============================ S3 GGUF 本地档 ============================
echo "S3 GGUF 本地档（非流式）"
set_cfg "AsrEngine=FunASRLocal" "LLMEnabled=True" "PopupTimeoutMs=3000"
base=$(record_and_play /samples/中文测试-16k.wav 8 中文)
if wait_state candidates 40; then ok "GGUF → candidates"; else bad "GGUF 未到 candidates: $(call State)"; fi
n_partial=$(( "$(grep -ac "partial:" /tmp/fcitx5.log || true)" - base ))
[ "$n_partial" -eq 0 ] && ok "非流式：录音期无 partial ✓" || bad "GGUF 不应有 partial（$n_partial 条）"
cand=$(call Candidates)
case "$cand" in *"这是一段语音测试"*) ok "GGUF 识别正确: ${cand:0:60}...";; *) bad "GGUF 候选异常: $cand";; esac
call SimulateKey 1 true >/dev/null; sleep 0.6
txt=$(last_text)
case "$txt" in *"这是一段语音测试"*) ok "GGUF 落点=…${txt: -20}";; *) bad "GGUF 落点异常=[$txt]";; esac

# ============================ S4 Dummy 回归 ============================
echo "S4 Dummy 回归"
set_cfg "AsrEngine=Dummy" "DummyText=回归正常" "LLMEnabled=True" \
        "DummyStream=True" "PopupTimeoutMs=3000"
call SimulateKey Control_R true >/dev/null; sleep 1.2
call SimulateKey Control_R false >/dev/null
if wait_state candidates 8; then ok "Dummy → candidates"; else bad "Dummy 异常: $(call State)"; fi
call SimulateKey 1 true >/dev/null; sleep 0.5
txt=$(last_text)
case "$txt" in *"回归正常"*) ok "Dummy 落点 ✓";; *) bad "Dummy 落点异常=[$txt]";; esac

sleep 1
kill -INT $REC 2>/dev/null; sleep 2
kill %1 %2 %3 2>/dev/null

# UI 可见性防回归：录屏中应出现悬浮面板（防 IM 前端/桥断裂类回归）
if command -v ffmpeg >/dev/null && [ -f /tmp/f6.mp4 ]; then
    vis=$(python3 - <<'PYEOF'
import subprocess
W, H = 1280, 720
p = subprocess.Popen(["ffmpeg","-v","error","-i","/tmp/f6.mp4",
    "-f","rawvideo","-pix_fmt","rgb24","-"], stdout=subprocess.PIPE)
fs = W*H*3; counts=[]
while True:
    b = p.stdout.read(fs)
    if len(b) < fs: break
    c = 0
    for y in range(30, 690, 12):
        base = y*W
        for x in range(100, 900, 12):
            i = (base+x)*3
            if b[i] > 195 and b[i+1] > 195 and b[i+2] > 195: c += 1
    counts.append(c)
base = sorted(counts[:20])[len(counts[:20])//2] if counts else 0
print(sum(1 for c in counts if c > base + 60))
PYEOF
)
    if [ "${vis:-0}" -gt 5 ]; then
        ok "录屏中悬浮面板可见（${vis} 帧）"
    else
        bad "录屏中未见到悬浮面板（${vis:-0} 帧）——检查 IM 前端/帧桥"
    fi
fi

echo "=============================="
echo "F6 结果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "F6 真实音频端到端：全部通过 ✓" || echo "F6：存在失败 ✗"
