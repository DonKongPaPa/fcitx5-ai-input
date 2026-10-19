#!/usr/bin/env bash
# 动画卡顿归因诊断（CASE_DRIVER 覆盖进 niri 环境）：
#   Dummy 流式长文本 → 卡片多台阶纵向生长；录屏 + journal 矩形变化日志，
#   归因"纵向拉伸/横向移动一顿一顿"是合成器侧还是输入法侧。
#   帧级分析在宿主侧做（ffmpeg 抽帧 + PIL bbox 轨迹 + vision 裁剪帧检查）。
# 产物：$OUT_DIR/rec-anim.mp4 + timeline.txt + 截图；journal 在 fcitx5.log
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

unset GTK_IM_MODULE QT_IM_MODULE SDL_IM_MODULE XMODIFIERS

DIST_BIN="${DIST_BIN:-/opt/dist/bin}"
TESTAPP="${TESTAPP:-testapp-gtk}"
RECORDER_OPTS="${RECORDER_OPTS:---no-dmabuf}"
TEST_SCALE="${NIRI_TEST_SCALE:-2.0}"
LOGICAL_W=$(python3 -c "print(int(1920/float('$TEST_SCALE')))")
LOGICAL_H=$(python3 -c "print(int(1080/float('$TEST_SCALE')))")

FCITX_LOG="$LOG_DIR/fcitx5.log"
call() { timeout 30 gdbus call --session --dest org.fcitx.Fcitx5 \
    --object-path /org/fcitx/AiInput \
    --method org.fcitx.AiInput.Test."$1" "${@:2}" 2>&1; }
set_cfg() { timeout 30 gdbus call --session --dest org.fcitx.Fcitx5 \
    --object-path /controller --method org.fcitx.Fcitx.Controller1.SetConfig \
    "fcitx://config/addon/aiinput" "$1" >/dev/null 2>&1 || true; }
state_is() { case "$(call State 2>/dev/null || true)" in *"$1"*) return 0;; *) return 1;; esac; }
mark() { MARK=$(wc -l < "$FCITX_LOG"); }

rec_start() {
    rm -f "$OUT_DIR/rec-$1.mp4"
    WAYLAND_DISPLAY="$CAGE_SOCK" wf-recorder $RECORDER_OPTS --codec libx264 -p crf=0 -r 30 \
        -f "$OUT_DIR/rec-$1.mp4" >"$LOG_DIR/wf-recorder-$1.log" 2>&1 &
    REC_PID=$!
    sleep 0.7
}
rec_stop() {
    [ -n "${REC_PID:-}" ] || return 0
    kill -INT "$REC_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$REC_PID" 2>/dev/null || break; sleep 0.3; done
    kill -9 "$REC_PID" 2>/dev/null || true
    wait "$REC_PID" 2>/dev/null || true
    REC_PID=""
}

# 长流式文本：~90 CJK 字 → 卡宽 [360,420] 下 3-4 行 → 3 个纵向生长台阶
LONG_TEXT="这是一个用于动画归因诊断的长文本样本需要足够长以便在卡片宽度约束下换行成多行从而触发卡片纵向生长的多个台阶每个台阶对应一次窗口尺寸变化"
set_cfg "<{'DummyText': <'$LONG_TEXT'>, 'DummyStreamIntervalMs': <'60'>, 'PopupTimeoutMs': <'3000'>}>"
sleep 1

TESTAPP_GEOMETRY=1900x1000 "$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-anim.log" 2>&1 &
sleep 2

rec_start anim
{
    echo "rec-start $(date +%s.%N)"
    # 会话：触发（preedit 进入=横移事件 A）→ 流式生长（纵向台阶）→ 松开
    # → result/候选 → 超时自动上屏（preedit 清除=横移事件 B）→ idle
    echo "trigger-down $(date +%s.%N)"
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
    sleep 4
    echo "trigger-up $(date +%s.%N)"
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 1.5
    echo "result-phase $(date +%s.%N)"
    sleep 3.5
    echo "session-end $(date +%s.%N)"
} | tee "$OUT_DIR/timeline.txt"

WAYLAND_DISPLAY="$CAGE_SOCK" grim "$OUT_DIR/anim-final.png" 2>/dev/null || true
rec_stop
echo "== journal 矩形变化（本次窗口）"
grep -a "光标矩形变化\|VoicePopup: show\|VoicePopup: popup 已 unmap" "$FCITX_LOG" | tail -20 || true
echo "anim-driver 完成"
