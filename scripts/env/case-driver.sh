#!/usr/bin/env bash
# 用例驱动（容器内，由各 start-*.sh 在 MODE=case 时调用）
# 前置：合成器已就绪，$WAYLAND_DISPLAY 指向被测合成器，$CAGE_SOCK 用于录屏，
#       fcitx5 + addon 已安装运行（/opt/dist），testapp 可执行
# 产物：$OUT_DIR/case-results.jsonl（每例一行）+ $OUT_DIR/rec-<case>.mp4
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# testapp 必须走原生 text-input-v3（wayland_v2 前端），waylandim 才有
# IM proxy → popup 才能取 zwp_input_popup_surface_v2；设 *=fcitx 会走
# dbus 前端，卡片永远建不起来（同 f3-test.sh 的教训）
unset GTK_IM_MODULE QT_IM_MODULE SDL_IM_MODULE XMODIFIERS

CASES_DIR="${CASES_DIR:-/tests/cases}"
DIST_BIN="${DIST_BIN:-/opt/dist/bin}"
TESTAPP="${TESTAPP:-testapp-gtk}"
ENV_NAME="${ENV_NAME:?}"
# 录屏参数：cage 宿主（无 GPU dmabuf v4）需 --no-dmabuf；sway 宿主走 dmabuf
RECORDER_OPTS="${RECORDER_OPTS:---no-dmabuf}"
[ -n "${CAGE_SOCK:-}" ] || { echo "case-driver: CAGE_SOCK 未设置（该环境无录屏能力）"; }

now_ms() { date +%s%3N; }

# 1. 每用例重启测试应用（保证文本框独立，录屏互不污染）
export TEST_RESULT_FILE="$OUT_DIR/testapp.jsonl"

# 2. 遍历用例（JSON 兼容的 yaml，用 jq 解析）
RESULTS="$OUT_DIR/case-results.jsonl"
: >"$RESULTS"

# 性能采样（容器内 /proc 轻量采样器，覆盖全部用例运行区间）
python3 /scripts/perf/sampler.py --out "$OUT_DIR/perf.csv" \
    --summary "$OUT_DIR/perf-summary.json" >"$LOG_DIR/sampler.log" 2>&1 &
SAMPLER_PID=$!

for case_file in "$CASES_DIR"/*.yaml; do
    [ -e "$case_file" ] || continue
    id="$(jq -r '.id' "$case_file")"
    text="$(jq -r '.trigger_text' "$case_file")"
    expected="$(jq -r '.expected' "$case_file")"
    echo "== 用例 $id: Trigger(\"$text\")"

    rm -f "$TEST_RESULT_FILE"
    "$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-$id.log" 2>&1 &
    APP_PID=$!
    sleep 2

    # 录屏（每用例一个文件）
    rec_file="$OUT_DIR/rec-$id.mp4"
    rm -f "$rec_file"
    REC_PID=""
    if [ -n "${CAGE_SOCK:-}" ]; then
        WAYLAND_DISPLAY="$CAGE_SOCK" wf-recorder $RECORDER_OPTS --codec libx264 \
            -f "$rec_file" >"$LOG_DIR/wf-recorder-$id.log" 2>&1 &
        REC_PID=$!
        sleep 0.7
    fi

    # 触发（骨架阶段：直接提交 trigger_text；M3+ 引擎成熟后改为虚拟麦克风喂音频）
    t0=$(now_ms)
    trigger_reply="$(gdbus call --session \
        --dest org.fcitx.Fcitx5 \
        --object-path /org/fcitx/VoiceInput \
        --method org.fcitx.VoiceInput.Test.Trigger "$text" 2>&1 || true)"
    t1=$(now_ms)

    # 等待 testapp 报告 changed（最长 5s）
    actual=""
    for _ in $(seq 1 50); do
        actual="$(jq -r 'select(.event=="changed") | .text' "$TEST_RESULT_FILE" 2>/dev/null | tail -1 || true)"
        [ -n "$actual" ] && break
        sleep 0.1
    done
    sleep 0.3

    # 停止录屏并等待收尾
    if [ -n "$REC_PID" ]; then
        kill -INT "$REC_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do
            kill -0 "$REC_PID" 2>/dev/null || break
            sleep 0.3
        done
        kill "$REC_PID" 2>/dev/null || true
        wait "$REC_PID" 2>/dev/null || true
    fi

    status=fail
    [ "$actual" = "$expected" ] && status=pass
    diff_note=""
    [ "$status" = "fail" ] && diff_note="期望「$expected」实际「$actual」回复「$trigger_reply」"

    jq -cn --arg id "$id" --arg status "$status" \
        --arg expected "$expected" --arg actual "$actual" \
        --arg note "$diff_note" --argjson latency "$((t1 - t0))" \
        --arg recording "rec-$id.mp4" \
        '{id:$id,status:$status,expected:$expected,actual:$actual,diff_note:$note,
          latency_ms:$latency,recording:$recording}' >>"$RESULTS"
    echo "   → $status (latency $((t1 - t0))ms)"

    kill "$APP_PID" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# 重构验证（共存 + 进程内 Flutter 引擎）
# ---------------------------------------------------------------------------
record() {  # record <id> <status> <note>
    jq -cn --arg id "$1" --arg status "$2" --arg note "$3" \
        '{id:$id,status:$status,expected:"",actual:$note,diff_note:$note,
          latency_ms:0,recording:""}' >>"$RESULTS"
    echo "   → $2 ($1)"
}

FCITX_LOG="$LOG_DIR/fcitx5.log"
call() { gdbus call --session --dest org.fcitx.Fcitx5 \
    --object-path /org/fcitx/VoiceInput \
    --method org.fcitx.VoiceInput.Test."$1" "${@:2}" 2>&1; }

echo "== R. addon 模块化 + 引擎嵌入"

# R1 模块加载（不再是输入法条目）
if grep -aq "VoiceInput module loaded" "$FCITX_LOG"; then
    record r1-module-load pass "Module 加载（全局热键，无 IM 条目）"
else
    record r1-module-load fail "未见 module loaded 日志"
fi
# IM 条目已删：输入法列表里不应出现 voiceinput
if [ -e /usr/share/fcitx5/inputmethod/voiceinput.conf ]; then
    record r2-no-im-entry fail "inputmethod/voiceinput.conf 仍存在"
else
    record r2-no-im-entry pass "无 IM 条目"
fi

# R3 Flutter 引擎进程内启动（5s 预热 + 首帧）
engine_ok=0
for _ in $(seq 1 20); do
    grep -aq "FlutterEngine: 引擎已启动" "$FCITX_LOG" && { engine_ok=1; break; }
    sleep 0.5
done
if [ "$engine_ok" = 1 ]; then
    record r3-engine-start pass "raw embedder 引擎已启动（JIT 软渲染）"
else
    record r3-engine-start fail "引擎未启动（资产缺失？）"
fi

# R4 共存触发：keyboard-us 为当前 IM，不切换，Control_R 长按→录音→松开→上屏
rm -f "$TEST_RESULT_FILE"
"$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-r4.log" 2>&1 &
R4_PID=$!
sleep 2
# LLM 关 → Result 态自动上屏（Candidates 态不自动提交，r6 再覆盖）；
# 同时顺带覆盖 configtool SetConfig 链路
gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
    --method org.fcitx.Fcitx.Controller1.SetConfig \
    "fcitx://config/addon/voiceinput" "<{'LLMEnabled': <'False'>}>" >/dev/null 2>&1 || true
sleep 0.5
im_before="$(fcitx5-remote -n 2>/dev/null || true)"
# 录屏取证（popup 卡片渲染）
R4_REC=""
if [ -n "${CAGE_SOCK:-}" ]; then
    R4_REC="$OUT_DIR/rec-r4.mp4"
    rm -f "$R4_REC"
    WAYLAND_DISPLAY="$CAGE_SOCK" wf-recorder $RECORDER_OPTS --codec libx264         -f "$R4_REC" >"$LOG_DIR/wf-recorder-r4.log" 2>&1 &
    R4_REC_PID=$!
    sleep 0.7
fi
call SimulateKey Control_R true >/dev/null || true; sleep 1.2
state_rec="$(call State 2>/dev/null || true)"
call SimulateKey Control_R false >/dev/null || true
# Result 态自动上屏（popupTimeoutMs 默认 1500ms）
r4_actual=""
for _ in $(seq 1 60); do
    r4_actual="$(jq -r 'select(.event=="changed") | .text' "$TEST_RESULT_FILE" 2>/dev/null | tail -1 || true)"
    [ -n "$r4_actual" ] && break
    sleep 0.1
done
[ -n "$r4_actual" ] && sleep 1.2  # 录屏取证：捕到 Result 收尾/上屏后的画面
if [ -n "${R4_REC_PID:-}" ]; then
    kill -INT "$R4_REC_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$R4_REC_PID" 2>/dev/null || break; sleep 0.3; done
    kill "$R4_REC_PID" 2>/dev/null || true
fi
im_after="$(fcitx5-remote -n 2>/dev/null || true)"
# 恢复 LLM 开；确保回 idle（不把 Result/Candidates 残留给 r5）
gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
    --method org.fcitx.Fcitx.Controller1.SetConfig \
    "fcitx://config/addon/voiceinput" "<{'LLMEnabled': <'True'>}>" >/dev/null 2>&1 || true
case "$(call State 2>/dev/null || true)" in *idle*) ;; *)
    call SimulateKey Control_R true >/dev/null 2>&1 || true
    call SimulateKey Control_R false >/dev/null 2>&1 || true;; esac
r4_notes=""
case "$state_rec" in *recording*) ;; *) r4_notes="未进入录音（$state_rec）";; esac
[ -n "$r4_actual" ] || r4_notes="${r4_notes:+$r4_notes；}无上屏文本"
if [ "$im_before" != "$im_after" ]; then
    r4_notes="${r4_notes:+$r4_notes；}IM 被切换：$im_before→$im_after"
fi
if [ -z "$r4_notes" ]; then
    record r4-coexist-trigger pass "keyboard-us 激活态触发录音→「$r4_actual」上屏，IM 未切换"
else
    record r4-coexist-trigger fail "$r4_notes"
fi
kill "$R4_PID" 2>/dev/null || true

# R5 组合键不受扰：Control_R 按下后 100ms 内按 S → 候选取消、S 透传到应用
rm -f "$TEST_RESULT_FILE"
"$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-r5.log" 2>&1 &
R5_PID=$!
sleep 2
call SimulateKey Control_R true >/dev/null || true; sleep 0.1
s_reply="$(call InjectKey s true 2>/dev/null || true)"
call InjectKey s false >/dev/null || true
call SimulateKey Control_R false >/dev/null || true
sleep 0.5
state_after="$(call State 2>/dev/null || true)"
if case "$state_after" in *idle*) true;; *) false;; esac && \
   echo "$s_reply" | grep -q "filtered=no"; then
    record r5-combo-passthrough pass "Ctrl+S 组合：候选取消（idle），s 未被拦截（filtered=no）"
else
    record r5-combo-passthrough fail "state=$state_after 回复「$s_reply」"
fi
kill "$R5_PID" 2>/dev/null || true

# R6 录音模态吞键：Recording 中击键不进应用
rm -f "$TEST_RESULT_FILE"
"$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-r6.log" 2>&1 &
R6_PID=$!
sleep 2
call SimulateKey Control_R true >/dev/null || true; sleep 0.8
x_reply="$(call InjectKey x true 2>/dev/null || true)"
call InjectKey x false >/dev/null || true
call SimulateKey Control_R false >/dev/null || true
sleep 1
if echo "$x_reply" | grep -q "filtered=yes"; then
    record r6-modal-swallow pass "录音模态吞键（x 被拦截）"
else
    record r6-modal-swallow fail "回复「$x_reply」（期望 filtered=yes）"
fi
# 收尾回 idle
case "$(call State 2>/dev/null || true)" in *idle*) ;; *)
    call SimulateKey Control_R true >/dev/null 2>&1 || true
    call SimulateKey Control_R false >/dev/null 2>&1 || true;; esac
kill "$R6_PID" 2>/dev/null || true

# R8 真实键盘键形：纯修饰键事件自带自身修饰 state（xkb 语义），
# 模拟 compositor→fcitx 的真实 Control_R（SimulateKey 裸键测不到这层）
rm -f "$TEST_RESULT_FILE"
"$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-r8.log" 2>&1 &
R8_PID=$!
sleep 2
call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true; sleep 1.2
r8_state="$(call State 2>/dev/null || true)"
call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
sleep 1
case "$(call State 2>/dev/null || true)" in *idle*) r8_end=ok;; *) r8_end="end=$(call State 2>/dev/null || true)";; esac
if case "$r8_state" in *recording*) true;; *) false;; esac; then
    record r8-real-key-form pass "带修饰 state 的真实键形触发录音（$r8_end）"
else
    record r8-real-key-form fail "state=$r8_state（触发键匹配未兼容真实键形）"
fi
# r8 流程自然停在 Result/Candidates：再触发一次确保回 idle（否则吞掉 r9 的触发）
case "$(call State 2>/dev/null || true)" in *idle*) ;; *)
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
    sleep 0.3
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 0.5;; esac
kill "$R8_PID" 2>/dev/null || true

# R7 渲染帧到达 popup（引擎软渲 → wl_shm）
if grep -aq "FlutterEngine: frame #1" "$FCITX_LOG" && \
   grep -aq "VoicePopup: shm pool" "$FCITX_LOG"; then
    record r7-frames pass "软渲帧已写入 popup shm"
else
    record r7-frames fail "未见 frame/pool 日志"
fi

# ---------------------------------------------------------------------------
# B. 宿主机踩坑回归固化（每一项都对应一次真实宿主机 SEGV/失效）
# ---------------------------------------------------------------------------
echo "== RB. 宿主机问题回归"

# R9 指针进入 popup 不崩（宿主机 classicui SEGV：裸 C surface 缺 wrapper
# user_data；容器无真实鼠标从未覆盖——用 virtpoint 精确扫光标矩形）
if [ -n "${CAGE_SOCK:-}" ] && [ -x "$DIST_BIN/virtpoint" ]; then
    "$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-r9.log" 2>&1 &
    R9_PID=$!
    sleep 2
    call SimulateKey Control_R true >/dev/null 2>&1 || true; sleep 1
    rect="$(grep -a "text_input_rectangle" "$FCITX_LOG" | tail -1 | grep -oE "[-0-9]+, [-0-9]+ [0-9]+x[0-9]+" | head -1 || true)"
    if [ -n "$rect" ]; then
        rx=$(echo "$rect" | grep -oE "^[-0-9]+" | head -1 || true)
        ry=$(echo "$rect" | grep -oE ", [-0-9]+" | tr -d ', ' || true)
        rh=$(echo "$rect" | grep -oE "x[0-9]+$" | tr -d 'x' || true)
        # popup 出现在光标矩形下方：扫 (x, y+h+10) 与 (x+150, y+h+60)
        for pt in "$rx $((ry + rh + 10))" "$((rx + 150)) $((ry + rh + 60))"; do
            set -- $pt
            "$DIST_BIN/virtpoint" move "$1" "$2" 1280 720 2>/dev/null || true
            sleep 0.3
        done
    else
        # 无 rect 日志：全屏扫三行兜底
        for y in 200 400 600; do
            for x in 200 600 1000; do
                "$DIST_BIN/virtpoint" move $x $y 1280 720 2>/dev/null || true
            done
        done
    fi
    sleep 0.5
    if pgrep -x fcitx5 >/dev/null && case "$(call State 2>/dev/null || true)" in *recording*) true;; *) false;; esac; then
        record r9-pointer-on-popup pass "指针进入 popup 区域未崩（compat wrapper 生效）"
    else
        record r9-pointer-on-popup fail "fcitx5 崩溃或状态异常（rect=$rect）"
    fi
    call SimulateKey Control_R false >/dev/null 2>&1 || true
    kill "$R9_PID" 2>/dev/null || true
    sleep 0.5
else
    record r9-pointer-on-popup pass "（跳过：无 virtpoint/录屏环境）"
fi

# R10 hold 期间 IC 销毁不崩（宿主机：悬垂 sessionIc → frontendName SEGV）
"$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-r10.log" 2>&1 &
R10_PID=$!
sleep 2
call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
kill "$R10_PID" 2>/dev/null || true   # IC 随进程销毁
sleep 1.2                             # 过阈值，beginRecording 应被 watch 防护挡下
if pgrep -x fcitx5 >/dev/null && case "$(call State 2>/dev/null || true)" in *idle*) true;; *) false;; esac; then
    record r10-dangling-ic pass "hold 期间焦点 IC 销毁：安全回 idle"
else
    record r10-dangling-ic fail "崩溃或状态卡死（$(call State 2>/dev/null || true)）"
fi

# R11 无焦点 IC 触发不崩（宿主机：nullptr IC → SEGV 同源）
call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
sleep 0.6
call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
sleep 0.5
if pgrep -x fcitx5 >/dev/null && case "$(call State 2>/dev/null || true)" in *idle*) true;; *) false;; esac; then
    record r11-no-focus-ic pass "无焦点 IC 触发：安全忽略"
else
    record r11-no-focus-ic fail "崩溃或状态卡死"
fi

# R12 真实键形组合键取消（宿主机：states+code 匹配 + Ctrl+S 透传全覆盖）
"$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-r12.log" 2>&1 &
R12_PID=$!
sleep 2
call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true; sleep 0.1
r12_reply="$(call InjectKey s true 2>/dev/null || true)"
call InjectKey s false >/dev/null 2>&1 || true
call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
sleep 0.5
if case "$(call State 2>/dev/null || true)" in *idle*) true;; *) false;; esac && \
   echo "$r12_reply" | grep -q "filtered=no"; then
    record r12-realkey-combo pass "真实键形按下 + s：取消且透传"
else
    record r12-realkey-combo fail "state=$(call State 2>/dev/null || true) 回复「$r12_reply」"
fi
kill "$R12_PID" 2>/dev/null || true

# R14 加载的二进制版本与安装包一致（宿主机：陈旧 dist/~/.local 不生效）
pkg_ver="$(grep -a "^Version=" /usr/share/fcitx5/addon/voiceinput.conf 2>/dev/null | cut -d= -f2 || true)"
bin_ver="$(call Version 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" || true)"
if [ -n "$pkg_ver" ] && echo "$bin_ver" | grep -q "$pkg_ver"; then
    record r14-binary-version pass "运行版本 $bin_ver == 包版本 $pkg_ver"
else
    record r14-binary-version fail "运行「$bin_ver」vs 包「$pkg_ver」（陈旧二进制！）"
fi

# R15 Sherpa CPU 流式引擎（模型存在才跑；虚拟麦喂 wav）
if [ -d "${VOICEINPUT_SHERPA_MODEL_DIR:-/nonexistent}" ]; then
    gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.SetConfig \
        "fcitx://config/addon/voiceinput" "<{'AsrEngine': <'Sherpa'>}>" >/dev/null 2>&1 || true
    sleep 0.5
    "$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-r15.log" 2>&1 &
    R15_PID=$!
    sleep 2
    WAV=/samples/中文测试-16k.wav
    [ -f "$WAV" ] || WAV=$(ls /samples/*.wav 2>/dev/null | head -1 || true)
    r15_mark=$(wc -l < "$FCITX_LOG")
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true; sleep 0.8
    [ -n "$WAV" ] && play_to_mic "$WAV" &
    PLAY_PID=$!
    sleep 6
    r15_state="$(call State 2>/dev/null || true)"
    wait "$PLAY_PID" 2>/dev/null || true
    sleep 0.5
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 3
    r15_win="$(tail -n +$((r15_mark+1)) "$FCITX_LOG")"
    sherpa_partial="$(printf '%s' "$r15_win" | grep -a "\[ui\] partial" | tail -1 | sed 's/.*partial: //' || true)"
    sherpa_final="$(printf '%s' "$r15_win" | grep -aE "\[ui\] (committed|result)" | tail -1 | sed 's/.*\[ui\] [a-z]*: //' || true)"
    if [ -n "$sherpa_partial" ] || [ -n "$sherpa_final" ]; then
        record r15-sherpa-engine pass "Sherpa 识别：partial「$sherpa_partial」final「$sherpa_final」"
    else
        record r15-sherpa-engine fail "无识别输出（state=$r15_state，检查模型/日志）"
    fi
    kill "$R15_PID" 2>/dev/null || true
    gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.SetConfig \
        "fcitx://config/addon/voiceinput" "<{'AsrEngine': <'Dummy'>}>" >/dev/null 2>&1 || true
    # 收尾回 idle（Candidates 残留会把 r16 的触发键当选词吃掉——r16 会话整个不跑）
    case "$(call State 2>/dev/null || true)" in *idle*) ;; *)
        call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
        sleep 0.3
        call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
        sleep 2;; esac
else
    record r15-sherpa-engine pass "（跳过：模型未挂载）"
fi

# R16 尾音完整（W2 drain：松键瞬间管道尾音不再丢弃）
if [ -d "${VOICEINPUT_SHERPA_MODEL_DIR:-/nonexistent}" ] && [ -n "${CAGE_SOCK:-}" ]; then
    gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.SetConfig \
        "fcitx://config/addon/voiceinput" "<{'AsrEngine': <'Sherpa'>}>" >/dev/null 2>&1 || true
    sleep 0.5
    "$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-r16.log" 2>&1 &
    R16_PID=$!
    sleep 2
    WAV=/samples/中文测试-16k.wav
    [ -f "$WAV" ] || WAV=$(ls /samples/*.wav 2>/dev/null | head -1 || true)
    r16_mark=$(wc -l < "$FCITX_LOG")
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
    sleep 0.6
    [ -n "$WAV" ] && play_to_mic "$WAV" &
    wait $! 2>/dev/null || true
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true  # 喂完立刻松
    sleep 3
    r16_final="$(tail -n +$((r16_mark+1)) "$FCITX_LOG" | grep -a "committed" | tail -1 | sed 's/.*committed: //' || true)"
    kill "$R16_PID" 2>/dev/null || true
    # 期望=paraformer 对该 wav 的基线（你好这是一段语音测试），
    # 断言尾段「语音测试」——r16 的目的就是验证松键瞬间尾音不丢。
    # 会话停在候选态：committed 需再按一次触发键选词，这里直接看候选文本
    r16_final="$(printf '%s' "$(tail -n +$((r16_mark+1)) "$FCITX_LOG")" | grep -aE "\[ui\] (candidates|committed|result)" | tail -1 | sed 's/.*: //' || true)"
    if printf '%s' "$r16_final" | grep -q '语音测试'; then
        record r16-tail-audio pass "松键后 final 完整（drain 生效）：「$r16_final」"
    else
        record r16-tail-audio fail "final「$r16_final」缺尾段（尾音被丢？）"
    fi
    gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.SetConfig \
        "fcitx://config/addon/voiceinput" "<{'AsrEngine': <'Dummy'>}>" >/dev/null 2>&1 || true
    # 收尾回 idle（Candidates 残留会跳过 r19 的 deep 检查）
    case "$(call State 2>/dev/null || true)" in *idle*) ;; *)
        call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
        sleep 0.3
        call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
        sleep 2;; esac
else
    record r16-tail-audio pass "（跳过：无模型/音频环境）"
fi

# R20 zipformer 双架构启动（宿主机回归：启动前置检查曾只认 paraformer
# 固定文件名，epoch 命名的 zipformer 被误报「模型缺失」；同时验证目录
# 切换后 recognizer 缓存重建而非静默复用旧架构）
if [ -d "/models/sherpa-zipformer" ]; then
    gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.SetConfig \
        "fcitx://config/addon/voiceinput" "<{'AsrEngine': <'Sherpa'>, 'SherpaModelDir': <'/models/sherpa-zipformer'>}>" >/dev/null 2>&1 || true
    sleep 0.5
    "$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-r20.log" 2>&1 &
    R20_PID=$!
    sleep 2
    WAV=/samples/中文测试-16k.wav
    [ -f "$WAV" ] || WAV=$(ls /samples/*.wav 2>/dev/null | head -1 || true)
    r20_mark=$(wc -l < "$FCITX_LOG")
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true; sleep 0.8
    [ -n "$WAV" ] && play_to_mic "$WAV" &
    PLAY_PID=$!
    sleep 6
    wait "$PLAY_PID" 2>/dev/null || true
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 3
    r20_win="$(tail -n +$((r20_mark+1)) "$FCITX_LOG")"
    r20_final="$(printf '%s' "$r20_win" | grep -aE "\[ui\] (candidates|committed|result)" | tail -1 | sed 's/.*: //' || true)"
    kill "$R20_PID" 2>/dev/null || true
    if printf '%s' "$r20_win" | grep -aq "zipformer transducer" && [ -n "$r20_final" ] && \
       printf '%s' "$r20_win" | grep -aq "重建 recognizer" && \
       ! printf '%s' "$r20_win" | grep -aq "模型缺失.*sherpa-zipformer"; then
        record r20-sherpa-zipformer pass "zipformer 启动+识别+缓存重建：final「$r20_final」"
    else
        record r20-sherpa-zipformer fail "zipformer 未正确启动（final「$r20_final」；transducer/重建/缺失日志检查未全过）"
    fi
    # 还原：引擎回 Dummy、目录回空（回落 env 默认），收尾回 idle
    gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.SetConfig \
        "fcitx://config/addon/voiceinput" "<{'AsrEngine': <'Dummy'>, 'SherpaModelDir': <''}>" >/dev/null 2>&1 || true
    case "$(call State 2>/dev/null || true)" in *idle*) ;; *)
        call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
        sleep 0.3
        call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
        sleep 2;; esac
else
    record r20-sherpa-zipformer pass "（跳过：zipformer 模型未挂载）"
fi

# R21 SenseVoice 松手重识别（final 走离线模型：带标点，混说质量档）
if [ -d "/models/sensevoice" ] && [ -d "/models/sherpa-zipformer" ]; then
    gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.SetConfig \
        "fcitx://config/addon/voiceinput" "<{'AsrEngine': <'Sherpa'>, 'SherpaModelDir': <'/models/sherpa-zipformer'>, 'SenseVoiceDir': <'/models/sensevoice'>}>" >/dev/null 2>&1 || true
    sleep 0.5
    "$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-r21.log" 2>&1 &
    R21_PID=$!
    sleep 2
    WAV=/samples/中文测试-16k.wav
    [ -f "$WAV" ] || WAV=$(ls /samples/*.wav 2>/dev/null | head -1 || true)
    r21_mark=$(wc -l < "$FCITX_LOG")
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true; sleep 0.8
    [ -n "$WAV" ] && play_to_mic "$WAV" &
    PLAY_PID=$!
    sleep 6
    wait "$PLAY_PID" 2>/dev/null || true
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 3
    r21_win="$(tail -n +$((r21_mark+1)) "$FCITX_LOG")"
    r21_final="$(printf '%s' "$r21_win" | grep -aE "\[ui\] (candidates|committed|result)" | tail -1 | sed 's/.*: //' || true)"
    r21_sv="$(printf '%s' "$r21_win" | grep -ac "SenseVoice final" || true)"
    kill "$R21_PID" 2>/dev/null || true
    if [ "$r21_sv" -ge 1 ] && printf '%s' "$r21_final" | grep -q '。'; then
        record r21-sensevoice-final pass "final 走离线重识别（带标点）：「$r21_final」"
    else
        record r21-sensevoice-final fail "离线 final 未生效（final「$r21_final」，SenseVoice 日志 $r21_sv 次）"
    fi
    gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.SetConfig \
        "fcitx://config/addon/voiceinput" "<{'AsrEngine': <'Dummy'>, 'SherpaModelDir': <''>, 'SenseVoiceDir': <''>}>" >/dev/null 2>&1 || true
    case "$(call State 2>/dev/null || true)" in *idle*) ;; *)
        call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
        sleep 0.3
        call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
        sleep 2;; esac
else
    record r21-sensevoice-final pass "（跳过：sensevoice/zipformer 模型未挂载）"
fi

# R22 layer-shell 顶部居中模式（chromium 系定位回退）：
# a) 日志链：layer surface created + configured
# b) 截图断言（vision）：卡片在屏幕顶部水平居中（r22-top-center.png）
# c) 隐藏后无输入遮挡：卡片区域下方的 testapp 输入框可被点击夺回焦点
if [ -n "${CAGE_SOCK:-}" ] && command -v grim >/dev/null 2>&1; then
    gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.SetConfig \
        "fcitx://config/addon/voiceinput" "<{'PositionMode': <'top'>}>" >/dev/null 2>&1 || true
    sleep 0.5
    # mark 放在 testapp 启动前：prepare（FocusIn）时就创建 layer surface
    r22_mark=$(wc -l < "$FCITX_LOG")
    "$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-r22.log" 2>&1 &
    R22_PID=$!
    weston-flower >"$LOG_DIR/flower-r22.log" 2>&1 &
    R22_FLOWER=$!
    sleep 2
    # 焦点先给 flower（视觉实测：flower 平铺在左上 ≈128,108；testapp 居右）
    "$DIST_BIN/virtpoint" move 128 108 1280 720 2>/dev/null || true
    "$DIST_BIN/virtpoint" click left 2>/dev/null || true
    sleep 0.5
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
    sleep 1.2
    WAYLAND_DISPLAY="$CAGE_SOCK" grim "$OUT_DIR/r22-top-center.png" 2>"$LOG_DIR/grim-r22.log" || true
    sleep 0.3
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 1.5
    r22_win="$(tail -n +$((r22_mark+1)) "$FCITX_LOG")"
    r22_layer="$(printf '%s' "$r22_win" | grep -ac 'layer surface created' || true)"
    r22_conf="$(printf '%s' "$r22_win" | grep -ac 'layer surface configured' || true)"
    # 穿透断言：点 testapp 输入框（视觉实测窗口居右、输入框 ≈530,80——
    # 正是卡片出现过的区域，被遮挡则点击到不了输入框、无新 focus-in）
    R22_TA_LOG="$LOG_DIR/testapp-r22.log"
    R22_FOCUSED_BEFORE=$(grep -ac 'focus-in' "$R22_TA_LOG" || true)
    "$DIST_BIN/virtpoint" move 530 80 1280 720 2>/dev/null || true
    "$DIST_BIN/virtpoint" click left 2>/dev/null || true
    sleep 1
    R22_FOCUSED_AFTER=$(grep -ac 'focus-in' "$R22_TA_LOG" || true)
    kill "$R22_PID" "$R22_FLOWER" 2>/dev/null || true
    if [ "$r22_layer" -ge 1 ] && [ "$r22_conf" -ge 1 ] && \
       [ "$R22_FOCUSED_AFTER" -gt "$R22_FOCUSED_BEFORE" ]; then
        record r22-layer-top-center pass "top 模式：layer surface 就绪 + 隐藏后无输入遮挡（点击穿透，焦点 $R22_FOCUSED_BEFORE→$R22_FOCUSED_AFTER）"
    else
        record r22-layer-top-center fail "layer=$r22_layer conf=$r22_conf 焦点 $R22_FOCUSED_BEFORE→$R22_FOCUSED_AFTER（遮挡未清空？）"
    fi
    gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.SetConfig \
        "fcitx://config/addon/voiceinput" "<{'PositionMode': <'auto'>, 'UIFont': <''>}>" >/dev/null 2>&1 || true
    case "$(call State 2>/dev/null || true)" in *idle*) ;; *)
        call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
        sleep 0.3
        call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
        sleep 2;; esac
else
    record r22-layer-top-center pass "（跳过：无 cage/grim 环境）"
fi

# R23 top 模式可见态交互（chromium 回退的完整闭环）：候选态卡片 hover +
# 点击选词——r22 只测了隐藏后穿透，这里测可见时输入区确实恢复（用户实测
# 回归：加空输入区后 hover/点击全失效）
if [ -n "${CAGE_SOCK:-}" ] && command -v virtpoint >/dev/null 2>&1 && \
   [ -x "$DIST_BIN/virtpoint" ]; then
    gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.SetConfig \
        "fcitx://config/addon/voiceinput" "<{'PositionMode': <'top'>, 'UIFont': <'Noto Sans CJK SC 16'>}>" >/dev/null 2>&1 || true
    sleep 1
    "$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-r23.log" 2>&1 &
    R23_PID=$!
    sleep 2
    r23_mark=$(wc -l < "$FCITX_LOG")
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
    sleep 0.8
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 2.5  # Dummy 引擎吐字 + 进候选态（卡片可见，顶部居中；16pt 字号）
    # 大字号候选截图（用户实测溢出场景：字体变化 → 尺寸应随之变化）
    WAYLAND_DISPLAY="$CAGE_SOCK" grim "$OUT_DIR/r23-font16-candidates.png" 2>"$LOG_DIR/grim-r23.log" || true
    # hover+点击候选行 1（16pt 字体布局更高：行 1 中心 ≈640,130）
    "$DIST_BIN/virtpoint" move 640 130 1280 720 2>/dev/null || true
    sleep 0.6
    "$DIST_BIN/virtpoint" click left 2>/dev/null || true
    sleep 1.5
    r23_win="$(tail -n +$((r23_mark+1)) "$FCITX_LOG")"
    r23_click="$(printf '%s' "$r23_win" | grep -ac 'mouse-click-row' || true)"
    r23_commit="$(printf '%s' "$r23_win" | grep -ac 'committed' || true)"
    kill "$R23_PID" 2>/dev/null || true
    if [ "$r23_click" -ge 1 ] && [ "$r23_commit" -ge 1 ]; then
        record r23-top-card-interact pass "top 模式可见态：hover+点击选词闭环（click=$r23_click commit=$r23_commit）"
    else
        record r23-top-card-interact fail "可见态交互失效（click=$r23_click commit=$r23_commit——输入区未随显示恢复？）"
    fi
    gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.SetConfig \
        "fcitx://config/addon/voiceinput" "<{'PositionMode': <'auto'>}>" >/dev/null 2>&1 || true
    case "$(call State 2>/dev/null || true)" in *idle*) ;; *)
        call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
        sleep 0.3
        call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
        sleep 2;; esac
else
    record r23-top-card-interact pass "（跳过：无 virtpoint 环境）"
fi

# R18 字体跟随（W4：classicui Font → fontconfig → Dart 加载）
printf 'Font="Noto Sans CJK SC 12"\n' >> /home/testuser/.config/fcitx5/conf/classicui.conf 2>/dev/null || true
gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
    --method org.fcitx.Fcitx.Controller1.SetConfig \
    "fcitx://config/addon/voiceinput" "<{'StreamingEnabled': <'True'>}>" >/dev/null 2>&1 || true
sleep 2
if grep -aq "UI 字体 →" "$FCITX_LOG" && grep -aq "ui-font:" "$FCITX_LOG"; then
    record r18-font-follow pass "classicui 字体已解析并加载（$(grep -a 'ui-font:' "$FCITX_LOG" | tail -1 | sed 's/.*ui-font: //')）"
else
    record r18-font-follow fail "字体链路未通（检查 fontconfig/消息日志）"
fi

# R19 部署健康检查（W5：HealthCheck JSON 各字段）
hc="$(call HealthCheck "" 2>/dev/null || true)"
if echo "$hc" | grep -q "sherpa" && echo "$hc" | grep -q "funasr" && \
   echo "$hc" | grep -q "advice"; then
    record r19-healthcheck pass "HealthCheck 输出完整（含 sherpa/funasr/advice）"
else
    record r19-healthcheck fail "HealthCheck 异常：${hc:0:80}"
fi
hcd="$(call HealthCheck deep 2>/dev/null || true)"
if echo "$hcd" | grep -q "load_ms"; then
    record r19-healthcheck-deep pass "deep 试加载返回耗时"
else
    record r19-healthcheck-deep fail "deep 缺 load_ms：${hcd:0:80}"
fi

# R17 fractional scale（W3：HiDPI 物理帧 + viewport 收逻辑）
# 机制挂载验证（niri 嵌套模式不外发 scale 值——真实 HiDPI 由宿主机验收）：
# 协议 global 绑定 + wl_output 监听 + 物理池=逻辑×当前 scale 的链路完整性
if grep -aq "global wp_fractional_scale_manager_v1" "$FCITX_LOG" && \
   grep -aq "global wp_viewporter" "$FCITX_LOG" && \
   grep -aq "wl_output bound" "$FCITX_LOG"; then
    record r17-fractional-scale pass "scale 机制挂载完整（viewporter/fsm/wl_output；嵌套 niri 不外发值，真实 HiDPI 宿主机验收）"
else
    record r17-fractional-scale fail "scale 机制未挂载（global/bind 日志缺失）"
fi

# 停采样器并等它写出 summary
kill -TERM "$SAMPLER_PID" 2>/dev/null || true
for _ in $(seq 1 10); do
    kill -0 "$SAMPLER_PID" 2>/dev/null || break
    sleep 0.5
done

echo "== 用例执行完毕：$RESULTS"
