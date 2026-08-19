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
kill "$R8_PID" 2>/dev/null || true

# R7 渲染帧到达 popup（引擎软渲 → wl_shm）
if grep -aq "FlutterEngine: frame #1" "$FCITX_LOG" && \
   grep -aq "VoicePopup: shm pool" "$FCITX_LOG"; then
    record r7-frames pass "软渲帧已写入 popup shm"
else
    record r7-frames fail "未见 frame/pool 日志"
fi

# 停采样器并等它写出 summary
kill -TERM "$SAMPLER_PID" 2>/dev/null || true
for _ in $(seq 1 10); do
    kill -0 "$SAMPLER_PID" 2>/dev/null || break
    sleep 0.5
done

echo "== 用例执行完毕：$RESULTS"
