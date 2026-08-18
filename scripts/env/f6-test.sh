#!/usr/bin/env bash
# F6 真实音频端到端（FunASR 接入 + 交互观察点）：
#   S1 中文 WS 流式（真实 partial 渐进 + 候选 + 数字键落点）
#   S2 英语 WS（MLT 多语种 + Enter=选第一个）
#   S3 GGUF 本地档（非流式 + 鼠标点击候选选择 + hover）
#   S4 Dummy 回归
#   S5 LLM 关 + 真实音频（result 态 + 超时自动上屏）
# 观察点：popup 位置带、候选可见时长（≥2s）、hover 高亮、
#         录屏 UI 可见性、pointer 路由日志
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

# 默认指向容器网 funasr-gpu（编排见 run-f6.sh；宿主 127.0.0.1 形态用 env 覆盖）
FUNASR_URL="${FUNASR_URL:-ws://funasr-gpu:10095}"
# 鼠标点击坐标（输出空间 1280x720）。校准依据：text_input_rectangle 实测
# 窗口局部 (199,52)，窗口原点 gaps=200 → 光标全局 (399,252)，popup 顶部
# ≈302 → 候选1行中心 ≈(440,355)、候选2行 ≈(440,410)
CLICK_X="${CLICK_X:-440}"
CLICK_Y="${CLICK_Y:-355}"

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
# 禁用 classicui：UI 全走我们的 popup+flutter；且注入的虚拟指针流会触发
# classicui wl_pointer 回调的空指针 bug（SIGSEGV；stock classicui 在真实
# 桌面不会收到这些注入事件所以无恙）。addon conf 覆盖不可靠，用 CLI 开关
fcitx5 -d --replace --disable=classicui >/tmp/fcitx5.log 2>&1
/opt/dist/bin/testapp-gtk >/tmp/app.log 2>&1 &
for i in $(seq 1 40); do call State >/dev/null 2>&1 && break; sleep 0.5; done
sleep 2.5

# 录屏存档
date +%s.%N > /tmp/t-recorder
WAYLAND_DISPLAY=$cage_sock wf-recorder --no-dmabuf --codec libx264 -f /tmp/f6.mp4 >/tmp/wf.log 2>&1 &
REC=$!
sleep 1

last_text() { tail -1 "$TEST_RESULT_FILE" 2>/dev/null | grep -oP '"text":"\K[^"]*'; }

record_and_play() {  # $1=wav $2=录音时长秒
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

# ============================ S1 中文 WS 流式（数字键） ============================
echo "S1 中文 WS 流式识别（数字键选择）"
set_cfg "AsrEngine=FunASR" "FunASRUrl=$FUNASR_URL" "FunASRLanguage=中文" \
        "TriggerMode=HoldRelease" "TriggerThresholdMs=300" "LLMEnabled=True" \
        "PopupTimeoutMs=3000"
base=$(record_and_play /samples/中文测试-16k.wav 8)
if wait_state candidates 45; then ok "release → candidates"; else bad "未到 candidates: $(call State)"; fi
n_partial=$(( "$(grep -ac "partial:" /tmp/fcitx5.log || true)" - base ))
if [ "$n_partial" -ge 2 ] && grep -a "partial:" /tmp/fcitx5.log | tail -"$n_partial" | grep -aq "你"; then
    ok "录音期真实中文 partial ${n_partial} 条"
else
    bad "partial 异常（${n_partial} 条）"
fi
cand=$(call Candidates)
case "$cand" in *"你好，这是一段语音测试"*) ok "候选含识别全文";; *) bad "候选异常: $cand";; esac
sleep 2.5   # 候选停留（观察点：录屏里看得清）
call SimulateKey 1 true >/dev/null; sleep 0.6
txt=$(last_text)
case "$txt" in *"这是一段语音测试"*) ok "数字键1 落点=[$txt]";; *) bad "落点异常=[$txt]";; esac
case "$(call State)" in *idle*) ok "回到 idle";; *) bad "状态残留: $(call State)";; esac

# ============================ S2 英语 WS（Enter） ============================
echo "S2 英语 WS（Enter=选第一个）"
set_cfg "AsrEngine=FunASR" "FunASRUrl=$FUNASR_URL" "FunASRLanguage=英文" \
        "LLMEnabled=True" "PopupTimeoutMs=3000"
base=$(record_and_play /samples/英语测试-16k.wav 8)
if wait_state candidates 45; then ok "英语 → candidates"; else bad "英语未到 candidates: $(call State)"; fi
cand=$(call Candidates)
case "$cand" in *"English voice input test"*) ok "英语识别正确";; *) bad "英语候选异常: $cand";; esac
sleep 2.5   # 候选停留
call SimulateKey Return true >/dev/null; sleep 0.6
txt=$(last_text)
case "$txt" in *"English voice input test"*) ok "Enter 落点=[$txt]";; *) bad "Enter 落点异常=[$txt]";; esac
case "$(call State)" in *idle*) ok "Enter 后 idle";; *) bad "Enter 后状态: $(call State)";; esac

# ============================ S3 GGUF（鼠标点击 + hover） ============================
echo "S3 GGUF 本地档（鼠标点击选择 + hover 高亮）"
set_cfg "AsrEngine=FunASRLocal" "LLMEnabled=True" "PopupTimeoutMs=3000"
base=$(record_and_play /samples/中文测试-16k.wav 8)
if wait_state candidates 40; then ok "GGUF → candidates"; else bad "GGUF 未到 candidates: $(call State)"; fi
n_partial=$(( "$(grep -ac "partial:" /tmp/fcitx5.log || true)" - base ))
[ "$n_partial" -eq 0 ] && ok "非流式：录音期无 partial ✓" || bad "GGUF 不应有 partial（$n_partial 条）"
sleep 2.0   # 候选停留（hover + 点击在停留期内完成）
# hover：移到候选 2 行（行高 54；CLICK_Y 为候选 1 行中心）
Y2=$((CLICK_Y + 54))
virtpoint move "$CLICK_X" "$Y2" 1280 720 >/dev/null 2>&1
sleep 1.0
if grep -aq "hover-row" /tmp/fcitx5.log; then
    ok "hover 路由生效（$(grep -a 'hover-row' /tmp/fcitx5.log | tail -1 | grep -oP 'hover-row.*')）"
else
    bad "hover 未路由（检查 pointer enter 是否到达）"
fi
# 点击选择候选 2
before_cnt=$(wc -l < "$TEST_RESULT_FILE")
virtpoint click >/dev/null 2>&1
sleep 1.2
txt=$(last_text)
after_cnt=$(wc -l < "$TEST_RESULT_FILE")
click_log=$(grep -a "pointer button" /tmp/fcitx5.log | tail -1)
case "$click_log" in
*"→ row=1") ok "点击命中候选 2 行（pointer 日志: ${click_log##*VoicePopup: }）";;
*"→ row=0") bad "点击落在候选 1（CLICK_Y 偏一行）";;
*) bad "pointer 点击日志异常: ${click_log:-无}";;
esac
if [ "$after_cnt" -gt "$before_cnt" ] && case "$txt" in *测试*) true;; *) false;; esac; then
    ok "鼠标选择落点=…${txt: -12}"
else
    bad "鼠标选择无落点（$before_cnt→$after_cnt）"
fi
case "$(call State)" in *idle*) ok "点击后 idle";; *) bad "点击后状态: $(call State)";; esac

# ============================ S4 Dummy 回归 ============================
echo "S4 Dummy 回归"
set_cfg "AsrEngine=Dummy" "DummyText=回归正常" "LLMEnabled=True" \
        "DummyStream=True" "PopupTimeoutMs=3000"
call SimulateKey Control_R true >/dev/null; sleep 1.2
call SimulateKey Control_R false >/dev/null
if wait_state candidates 8; then ok "Dummy → candidates"; else bad "Dummy 异常: $(call State)"; fi
sleep 1.5
call SimulateKey 1 true >/dev/null; sleep 0.5
txt=$(last_text)
case "$txt" in *"回归正常"*) ok "Dummy 落点 ✓";; *) bad "Dummy 落点异常=[$txt]";; esac

# ============================ S5 LLM 关 + 真实音频（结果态） ============================
echo "S5 LLM 关 + 真实音频（result 态自动上屏）"
set_cfg "AsrEngine=FunASR" "FunASRUrl=$FUNASR_URL" "FunASRLanguage=中文" \
        "LLMEnabled=False" "PopupTimeoutMs=2500"
base=$(record_and_play /samples/中文测试-16k.wav 8)
if wait_state result 45; then ok "LLM 关 → result 态"; else bad "未到 result: $(call State)"; fi
sleep 3.5   # 超过 PopupTimeoutMs=2500 → 自动上屏
case "$(call State)" in *idle*) ok "超时自动上屏 → idle";; *) bad "超时未上屏: $(call State)";; esac
txt=$(last_text)
case "$txt" in *"这是一段语音测试"*) ok "result 落点=[$txt]";; *) bad "result 落点异常=[$txt]";; esac

sleep 1
kill -INT $REC 2>/dev/null; sleep 2
kill %1 %2 %3 2>/dev/null

# ============================ 观察点：录屏分析 ============================
if command -v ffmpeg >/dev/null && [ -f /tmp/f6.mp4 ]; then
    python3 - <<'PYEOF' > /tmp/f6-scan.txt
import subprocess, sys
W, H = 1280, 720
p = subprocess.Popen(["ffmpeg","-v","error","-i","/tmp/f6.mp4",
    "-f","rawvideo","-pix_fmt","rgb24","-"], stdout=subprocess.PIPE)
fs = W*H*3
frames = []
while True:
    b = p.stdout.read(fs)
    if len(b) < fs: break
    frames.append(b)
N = len(frames)

def panel_cells(b):
    # 紫调检测：MD3 surfaceContainerHigh 带紫 tint（b-r≈8），testapp 白底
    # b-r=0——纯亮度阈值在 valign 修复后会被窗口本底淹没
    pts = []
    for y in range(30, 690, 10):
        base = y*W
        for x in range(100, 900, 10):
            i = (base+x)*3
            if b[i] > 185 and b[i+1] > 180 and b[i+2] > 195 and 3 <= b[i+2] - b[i] <= 30:
                pts.append((x, y))
    return pts

counts = [len(panel_cells(f)) for f in frames]
base = sorted(counts[:20])[len(counts[:20])//2] if counts else 0
TH = base + 60
vis = [i for i, c in enumerate(counts) if c > TH]
print(f"VIS_FRAMES {len(vis)}")
print(f"TOTAL {N}")
if vis:
    # 最亮帧的包围盒 = popup 位置带
    best = max(vis, key=lambda i: counts[i])
    pts = panel_cells(frames[best])
    xs = [q[0] for q in pts]; ys = [q[1] for q in pts]
    print(f"PANEL_BBOX {min(xs)} {min(ys)} {max(xs)} {max(ys)}")
    # 候选可见时长：连续可见最长段
    run = best_run = 0
    for i in range(N):
        run = run + 1 if counts[i] > TH else 0
        best_run = max(best_run, run)
    print(f"MAX_VISIBLE_RUN {best_run}")
    # hover 高亮帧：候选期两帧差异（hover 行变色）——粗略用可见段内帧差
    if len(vis) > 30:
        diffs = []
        for a, b2 in zip(vis[:-1], vis[1:]):
            if b2 - a == 1:
                d = sum(abs(frames[a][i] - frames[b2][i])
                        for i in range(0, fs, 997))
                diffs.append(d)
        print(f"INRUN_DIFFS {sorted(diffs)[-5:] if diffs else []}")
PYEOF
    vis=$(grep -oP 'VIS_FRAMES \K\d+' /tmp/f6-scan.txt)
    bbox=$(grep "PANEL_BBOX" /tmp/f6-scan.txt)
    run=$(grep -oP 'MAX_VISIBLE_RUN \K\d+' /tmp/f6-scan.txt)
    total=$(grep -oP 'TOTAL \K\d+' /tmp/f6-scan.txt)
    if [ "${vis:-0}" -gt 5 ]; then
        ok "录屏悬浮面板可见（${vis}/${total} 帧）"
    else
        bad "录屏未见悬浮面板（${vis:-0} 帧）"
    fi
    if [ -n "$bbox" ]; then
        py=$(echo "$bbox" | awk '{print $3}')
        if [ -n "$py" ] && [ "$py" -ge 230 ] && [ "$py" -le 400 ]; then
            ok "popup 位置带正确（顶部 y=${py}，贴近窗口顶部输入行）"
        else
            bad "popup 位置异常（顶部 y=${py:-?}，期望 230-400）"
        fi
    fi
    if [ -n "$run" ] && [ "$run" -ge 10 ]; then
        ok "候选/结果连续可见 ≥2s（${run} 帧）"
    else
        bad "可见时长不足（${run:-0} 帧）"
    fi
fi

echo "=============================="
echo "F6 结果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "F6 真实音频端到端：全部通过 ✓" || echo "F6：存在失败 ✗"
