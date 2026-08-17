#!/usr/bin/env bash
# 用例驱动（容器内，由各 start-*.sh 在 MODE=case 时调用）
# 前置：合成器已就绪，$WAYLAND_DISPLAY 指向被测合成器，$CAGE_SOCK 用于录屏，
#       fcitx5 + addon 已安装运行（/opt/dist），testapp 可执行
# 产物：$OUT_DIR/case-results.jsonl（每例一行）+ $OUT_DIR/rec-<case>.mp4
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

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

# 停采样器并等它写出 summary
kill -TERM "$SAMPLER_PID" 2>/dev/null || true
for _ in $(seq 1 10); do
    kill -0 "$SAMPLER_PID" 2>/dev/null || break
    sleep 0.5
done

echo "== 用例执行完毕：$RESULTS"
