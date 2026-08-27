#!/usr/bin/env bash
# 用例驱动（容器内，由各 start-*.sh 在 MODE=case 时调用）
# 前置：合成器已就绪，$WAYLAND_DISPLAY 指向被测合成器，$CAGE_SOCK 用于录屏，
#       fcitx5 + addon 已安装运行（/opt/dist），testapp 可执行
# 产物：$OUT_DIR/case-results.jsonl（每例一行）+ 截图/录屏取证文件
#
# 用例地图（2026-08-26 重构，37→20）：
#   S 组 smoke  s1-s5   部署后运行检查（SUITE=smoke 单独快速跑）
#     s1 模块加载  s2 引擎+渲染帧  s3 版本一致  s4 基本会话 E2E  s5 HealthCheck
#   C 组 corner c1-c15  corner case 集中一轮（SUITE=corner；默认 all 两 组都跑）
#     键盘语义 c1  IC 生命周期 c2  看门狗 c3  失焦自愈 c4
#     定位：dbus 贴光标 c5  显式档+交互 c6  chromium 多幕 c7  GTK 重跟随 c8
#           首按+探针 c9  跨应用 c10  连续听写 c11
#     字体 c12  引擎（挂模型才跑）：sherpa+尾音 c13  zipformer c14  SenseVoice c15
# 门控：c13-c15 需挂载模型；c5-c11 需录屏/virtpoint/chromium——依赖缺失记
#   "pass（跳过）"。scale 维度由整轮 NIRI_TEST_SCALE 控制（非用例内）
# 收尾纪律：每个会话用例结束必须 back_to_idle（残留候选/录音会吞掉下一
#   用例的触发键——r24/r34/r37 三次教训）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# testapp 必须走原生 text-input-v3（wayland_v2 前端），waylandim 才有
# IM proxy → popup 才能取 zwp_input_popup_surface_v2；设 *=fcitx 会走
# dbus 前端，卡片永远建不起来（同 f3-test.sh 的教训）
unset GTK_IM_MODULE QT_IM_MODULE SDL_IM_MODULE XMODIFIERS

DIST_BIN="${DIST_BIN:-/opt/dist/bin}"
TESTAPP="${TESTAPP:-testapp-gtk}"
ENV_NAME="${ENV_NAME:?}"
# 录屏参数：cage 宿主（无 GPU dmabuf v4）需 --no-dmabuf；sway 宿主走 dmabuf
RECORDER_OPTS="${RECORDER_OPTS:---no-dmabuf}"
[ -n "${CAGE_SOCK:-}" ] || { echo "case-driver: CAGE_SOCK 未设置（该环境无录屏能力）"; }

SUITE="${SUITE:-all}"
suite() { case ",$SUITE," in *",all,"*|*",$1,"*) return 0;; *) return 1;; esac; }

# testapp 文本事件流（s4 上屏断言读它）
export TEST_RESULT_FILE="$OUT_DIR/testapp.jsonl"

RESULTS="$OUT_DIR/case-results.jsonl"
: >"$RESULTS"

record() {  # record <id> <status> <note> [rec-<id>.mp4]
    local rec="${4:-}"
    [ -n "$rec" ] && [ -s "$OUT_DIR/$rec" ] || rec=""
    jq -cn --arg id "$1" --arg status "$2" --arg note "$3" --arg rec "$rec" \
        '{id:$id,status:$status,expected:"",actual:$note,diff_note:$note,
          latency_ms:0,recording:$rec}' >>"$RESULTS"
    echo "   → $2 ($1)"
}

REC_PID=""
rec_start() {  # rec_start <case-id>：整例录屏（取证 + make baseline 素材）
    [ -n "${CAGE_SOCK:-}" ] || { REC_PID=""; return 0; }
    rm -f "$OUT_DIR/rec-$1.mp4"
    WAYLAND_DISPLAY="$CAGE_SOCK" wf-recorder $RECORDER_OPTS --codec libx264 -p crf=30 -r 24 \
        -f "$OUT_DIR/rec-$1.mp4" >"$LOG_DIR/wf-recorder-$1.log" 2>&1 &
    REC_PID=$!
    sleep 0.7
}
rec_stop() {
    [ -n "$REC_PID" ] || return 0
    kill -INT "$REC_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$REC_PID" 2>/dev/null || break; sleep 0.3; done
    kill -9 "$REC_PID" 2>/dev/null || true
    wait "$REC_PID" 2>/dev/null || true
    REC_PID=""
}

# xtrace 落盘：挂起类问题的直接证据（卡住的最后一行）
exec {XTRACEFD}>"$LOG_DIR/driver-trace.log"
export BASH_XTRACEFD
set -x

FCITX_LOG="$LOG_DIR/fcitx5.log"
call() { timeout 30 gdbus call --session --dest org.fcitx.Fcitx5 \
    --object-path /org/fcitx/AiInput \
    --method org.fcitx.AiInput.Test."$1" "${@:2}" 2>&1; }

set_cfg() {  # set_cfg "<{'K': <'v'>, ...}>"——值必须字符串（int32 被静默丢弃）
    timeout 30 timeout 30 gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.SetConfig \
        "fcitx://config/addon/aiinput" "$1" >/dev/null 2>&1 || true
}

state_is() { case "$(call State 2>/dev/null || true)" in *"$1"*) return 0;; *) return 1;; esac; }

back_to_idle() {  # 收敛到 idle：recording→release→candidates→press→idle
    for _ in 1 2 3; do
        state_is idle && return 0
        call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
        sleep 0.3
        call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
        sleep 1.6
    done
    return 0
}

# 性能采样（容器内 /proc 轻量采样器，覆盖全部用例运行区间）
python3 /scripts/perf/sampler.py --out "$OUT_DIR/perf.csv" \
    --summary "$OUT_DIR/perf-summary.json" >"$LOG_DIR/sampler.log" 2>&1 &
SAMPLER_PID=$!

# ===========================================================================
# S 组——部署后运行检查（每轮部署必跑；SUITE=smoke 约 1.5 分钟）
# ===========================================================================
if suite smoke; then
echo "== S. 部署后运行检查"

# s1 模块加载：Module 化（全局热键，无 IM 条目）
if grep -aq "AiInput module loaded" "$FCITX_LOG"; then
    s1_note="Module 加载（全局热键）"
    if [ -e /usr/share/fcitx5/inputmethod/aiinput.conf ]; then
        record s1-load fail "inputmethod/aiinput.conf 仍存在"
    else
        record s1-load pass "$s1_note + 无 IM 条目"
    fi
else
    record s1-load fail "未见 module loaded 日志"
fi

# s2 引擎+渲染帧：进程内 Flutter 启动（5s 预热）+ 软渲帧写入 popup shm
# ——等待而非瞬时快照（旧套件有 yaml 用例垫底时间，重构后 s2 是最早的
# 观察者，必须等预热完成）
s2_ok=0
for _ in $(seq 1 20); do
    if grep -aq "FlutterEngine: 引擎已启动" "$FCITX_LOG" && \
       grep -aq "VoicePopup: shm pool" "$FCITX_LOG"; then
        s2_ok=1; break
    fi
    sleep 0.5
done
if [ "$s2_ok" = 1 ]; then
    record s2-engine pass "引擎已启动（JIT 软渲）+ 帧已写入 popup shm"
else
    record s2-engine fail "引擎未启动或无渲染帧（10s 等待超时，检查资产/日志）"
fi

# s3 版本一致：运行二进制 == 安装包（宿主机回归：陈旧 dist/~/.local 不生效；
# 测试服务注册在 fcitx5 起后 ~1s，重试等待）
pkg_ver="$(grep -a "^Version=" /usr/share/fcitx5/addon/aiinput.conf 2>/dev/null | cut -d= -f2 || true)"
bin_ver=""
for _ in $(seq 1 10); do
    bin_ver="$(call Version 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1 || true)"
    [ -n "$bin_ver" ] && break
    sleep 0.5
done
if [ -n "$pkg_ver" ] && echo "$bin_ver" | grep -q "$pkg_ver"; then
    record s3-version pass "运行版本 $bin_ver == 包版本 $pkg_ver"
else
    record s3-version fail "运行「$bin_ver」vs 包「$pkg_ver」（陈旧二进制！）"
fi

# s4 基本会话 E2E：keyboard-us 激活态长按触发→录音→Result 自动上屏，IM 不切换
# （LLMEngine=Off → Result 态；顺带覆盖 SetConfig 配置链路）
"$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-s4.log" 2>&1 &
S4_PID=$!
sleep 2
rec_start s4
set_cfg "<{'LLMEngine': <'Off'>}>"
sleep 0.5
im_before="$(fcitx5-remote -n 2>/dev/null || true)"
rm -f "$TEST_RESULT_FILE"
call SimulateKey Control_R true >/dev/null || true; sleep 1.2
s4_state="$(call State 2>/dev/null || true)"
call SimulateKey Control_R false >/dev/null || true
s4_actual=""
for _ in $(seq 1 60); do
    s4_actual="$(jq -r 'select(.event=="changed") | .text' "$TEST_RESULT_FILE" 2>/dev/null | tail -1 || true)"
    [ -n "$s4_actual" ] && break
    sleep 0.1
done
im_after="$(fcitx5-remote -n 2>/dev/null || true)"
set_cfg "<{'LLMEngine': <'Dummy'>}>"
back_to_idle
kill "$S4_PID" 2>/dev/null || true
s4_notes=""
case "$s4_state" in *recording*) ;; *) s4_notes="未进入录音（$s4_state）";; esac
[ -n "$s4_actual" ] || s4_notes="${s4_notes:+$s4_notes；}无上屏文本"
[ "$im_before" = "$im_after" ] || s4_notes="${s4_notes:+$s4_notes；}IM 被切换：$im_before→$im_after"
if [ -z "$s4_notes" ]; then
    rec_stop
    record s4-session-e2e pass "共存态触发录音→「$s4_actual」自动上屏，IM 未切换" "rec-s4.mp4"
else
    rec_stop
    record s4-session-e2e fail "$s4_notes" "rec-s4.mp4"
fi

# s5 部署健康检查（HealthCheck JSON 各字段 + deep 试加载）
hc="$(call HealthCheck "" 2>/dev/null || true)"
hcd="$(call HealthCheck deep 2>/dev/null || true)"
if echo "$hc" | grep -q "sherpa" && echo "$hc" | grep -q "funasr" && \
   echo "$hc" | grep -q "advice" && { echo "$hcd" | grep -q "load_ms" || \
   [ ! -d "${AIINPUT_SHERPA_MODEL_DIR:-/nonexistent}" ]; }; then
    record s5-healthcheck pass "HealthCheck 输出完整（sherpa/funasr/advice + deep）"
else
    record s5-healthcheck fail "HealthCheck 异常：${hc:0:60} / deep：${hcd:0:60}"
fi
fi  # smoke

# ===========================================================================
# C 组——corner case 集中一轮（SUITE=corner；默认 all）
# ===========================================================================
if suite corner; then
echo "== C. corner cases"

# c1 键盘语义三连（宿主机 SEGV/失效回归）：真实键形触发（带自身修饰
# state）+ 模态吞键 + 组合键取消且透传
"$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-c1.log" 2>&1 &
C1_PID=$!
sleep 2
c1_notes=""
# ① 真实键形触发录音（SimulateKey "Control+Control_R"）
call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true; sleep 1.2
state_is recording || c1_notes="真实键形未触发录音（$(call State 2>/dev/null || true)）"
# ② 录音模态吞键
c1_x="$(call InjectKey x true 2>/dev/null || true)"
call InjectKey x false >/dev/null 2>&1 || true
echo "$c1_x" | grep -q "filtered=yes" || c1_notes="${c1_notes:+$c1_notes；}模态未吞键（$c1_x）"
call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
back_to_idle
# ③ 组合键取消 + 透传（Pressing 300ms 窗口内按 s）
call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true; sleep 0.1
c1_s="$(call InjectKey s true 2>/dev/null || true)"
call InjectKey s false >/dev/null 2>&1 || true
call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
sleep 0.5
state_is idle || c1_notes="${c1_notes:+$c1_notes；}组合未取消（$(call State 2>/dev/null || true)）"
echo "$c1_s" | grep -q "filtered=no" || c1_notes="${c1_notes:+$c1_notes；}s 未透传（$c1_s）"
back_to_idle
kill "$C1_PID" 2>/dev/null || true
if [ -z "$c1_notes" ]; then
    record c1-key-semantics pass "真实键形触发 + 模态吞键 + 组合取消透传"
else
    record c1-key-semantics fail "$c1_notes"
fi

# c2 IC 生命周期（宿主机 SEGV 回归）：hold 期 IC 销毁 + 无焦点触发
"$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-c2.log" 2>&1 &
C2_PID=$!
sleep 2
call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
kill "$C2_PID" 2>/dev/null || true   # IC 随进程销毁（悬垂 sessionIc）
sleep 1.2
c2_notes=""
pgrep -x fcitx5 >/dev/null || c2_notes="fcitx5 崩溃（悬垂 IC）"
state_is idle || c2_notes="${c2_notes:+$c2_notes；}hold+死IC 后状态异常"
call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true  # 无焦点 IC
sleep 0.6
call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
sleep 0.5
pgrep -x fcitx5 >/dev/null || c2_notes="${c2_notes:+$c2_notes；}fcitx5 崩溃（无 IC）"
state_is idle || c2_notes="${c2_notes:+$c2_notes；}无 IC 触发后状态异常"
if [ -z "$c2_notes" ]; then
    record c2-ic-lifecycle pass "悬垂 IC/无 IC 触发：安全回 idle"
else
    record c2-ic-lifecycle fail "$c2_notes"
fi

# c3 录音看门狗：焦点被抢后触发键 release 永远不来 → 录音无界（ghostty
# 末行卡死链）。MaxRecordingSec 调最小 10s：press 后不松，断言看门狗
# 自动结束 + 离开 recording + 可再触发
set_cfg "<{'MaxRecordingSec': <'10'>}>"
sleep 0.5
"$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-c3.log" 2>&1 &
C3_PID=$!
sleep 2
c3_mark=$(wc -l < "$FCITX_LOG")
call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
sleep 12.5
c3_state="$(call State 2>/dev/null || true)"
c3_win="$(tail -n +$((c3_mark+1)) "$FCITX_LOG")"
c3_wd="$(printf '%s' "$c3_win" | grep -ac '录音看门狗触发' || true)"
c3_stop="$(printf '%s' "$c3_win" | grep -ac 'recording-stop' || true)"
back_to_idle
c3_after="$(call State 2>/dev/null || true)"
kill "$C3_PID" 2>/dev/null || true
set_cfg "<{'MaxRecordingSec': <'60'>}>"
c3_ok=1; case "$c3_state" in *recording*) c3_ok=0;; esac
c3_fin=1; case "$c3_after" in *idle*) c3_fin=0;; esac
if [ "$c3_wd" -ge 1 ] && [ "$c3_stop" -ge 1 ] && [ "$c3_ok" = 1 ] && [ "$c3_fin" = 0 ]; then
    record c3-watchdog pass "无松开 10s 看门狗自动结束（终态 idle）"
else
    record c3-watchdog fail "wd=$c3_wd stop=$c3_stop 态=$c3_state 后=$c3_after"
fi

# c4 失焦自愈：录音中会话窗口失焦（新窗口夺焦）→ 自动结束识别
back_to_idle
c4_mark=$(wc -l < "$FCITX_LOG")
"$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-c4a.log" 2>&1 &
C4A=$!
sleep 2
call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
sleep 1
"$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-c4b.log" 2>&1 &
C4B=$!
sleep 2.5
c4_state="$(call State 2>/dev/null || true)"
c4_win="$(tail -n +$((c4_mark+1)) "$FCITX_LOG")"
c4_blur="$(printf '%s' "$c4_win" | grep -ac '会话 IC 失焦——自动结束' || true)"
c4_stop="$(printf '%s' "$c4_win" | grep -ac 'recording-stop' || true)"
back_to_idle
kill "$C4A" "$C4B" 2>/dev/null || true
c4_ok=1; case "$c4_state" in *recording*) c4_ok=0;; esac
if [ "$c4_blur" -ge 1 ] && [ "$c4_stop" -ge 1 ] && [ "$c4_ok" = 1 ]; then
    record c4-focusout pass "录音中失焦自动结束（终态 $c4_state）"
else
    record c4-focusout fail "blur=$c4_blur stop=$c4_stop 态=$c4_state"
fi

# c5 DBus IC 贴光标（DbusPosition=follow）：QT_IM_MODULE=fcitx 的 Qt 应用
# （DMS 启动器同型）maximize-column 铺满输出 → rect≈输出绝对坐标。
# a) 日志链：overlay 兜底 + 贴光标锚定  b) 像素：麦克风圆底质心在左侧 45%
if [ -n "${CAGE_SOCK:-}" ] && command -v grim >/dev/null 2>&1 && \
   [ -x "$DIST_BIN/testapp-qt" ]; then
    set_cfg "<{'DbusPosition': <'follow'>}>"
    sleep 0.5
    c5_mark=$(wc -l < "$FCITX_LOG")
    QT_IM_MODULE=fcitx "$DIST_BIN/testapp-qt" >"$LOG_DIR/testapp-c5.log" 2>&1 &
    C5_PID=$!
    sleep 2
    rec_start c5
    NIRI_SOCK_FILE="$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -m1 '^niri\.')"
    if [ -n "$NIRI_SOCK_FILE" ]; then
        NIRI_SOCKET="$XDG_RUNTIME_DIR/$NIRI_SOCK_FILE" niri msg action maximize-column >/dev/null 2>&1 || true
    fi
    sleep 0.8
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
    sleep 1.2
    WAYLAND_DISPLAY="$CAGE_SOCK" grim "$OUT_DIR/c5-dbus-follow.png" 2>"$LOG_DIR/grim-c5.log" || true
    sleep 0.3
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 1.5
    c5_win="$(tail -n +$((c5_mark+1)) "$FCITX_LOG")"
    c5_overlay="$(printf '%s' "$c5_win" | grep -ac 'overlay 兜底居中模式' || true)"
    c5_anchor="$(printf '%s' "$c5_win" | grep -ac '贴光标锚定' || true)"
    back_to_idle
    kill "$C5_PID" 2>/dev/null || true
    rec_stop
    set_cfg "<{'DbusPosition': <'bottom'>}>"
    c5_frac="$(python3 - "$OUT_DIR/c5-dbus-follow.png" <<'PYEOF' 2>/dev/null || echo "-1 -1"
import sys
try:
    from PIL import Image
except Exception:
    print(-1, -1); raise SystemExit(0)
im = Image.open(sys.argv[1]).convert('RGB')
w, h = im.size
px = im.load()
sx = sy = n = 0
for y in range(0, h, 2):
    for x in range(0, w, 2):
        r, g, b = px[x, y]
        # 录音态麦克风圆底（errorContainer 浅粉 #F9DEDC 一族）
        if r > 235 and 205 < g < 235 and 200 < b < 235 and r - g > 10:
            sx += x; sy += y; n += 1
print(f"{sx/n/w:.3f} {sy/n/h:.3f}" if n > 4 else "-1 -1")
PYEOF
)"
    c5_xf="${c5_frac%% *}"; c5_yf="${c5_frac##* }"
    if [ "$c5_overlay" -ge 1 ] && [ "$c5_anchor" -ge 1 ] && \
       python3 -c "import sys; sys.exit(0 if 0.0 <= float('$c5_xf') < 0.45 else 1)"; then
        record c5-dbus-follow pass "DBus IC 贴光标：overlay+锚定 + 圆底在左侧（x=$c5_xf y=$c5_yf）" "rec-c5.mp4"
    else
        record c5-dbus-follow fail "follow 未生效（overlay=$c5_overlay anchor=$c5_anchor x=$c5_xf y=$c5_yf）" "rec-c5.mp4"
    fi
else
    record c5-dbus-follow pass "（跳过：无截图环境）"
fi

# c6 显式档定位+交互闭环（PositionMode=top）：layer surface 就绪 + 可见态
# hover/点击/方向键选词 + 隐藏后输入区清空（点击穿透）
if [ -n "${CAGE_SOCK:-}" ] && command -v grim >/dev/null 2>&1 && \
   [ -x "$DIST_BIN/virtpoint" ]; then
    set_cfg "<{'PositionMode': <'top'>, 'UIFont': <'Noto Sans CJK SC 16'>}>"
    sleep 1
    # mark 在 testapp 启动前：prepare（FocusIn）时就创建 layer surface
    # （testapp 先启动拿到焦点→prepare；flower 随后抢走焦点只作穿透靶）
    c6_mark=$(wc -l < "$FCITX_LOG")
    "$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-c6.log" 2>&1 &
    C6_PID=$!
    weston-flower >"$LOG_DIR/flower-c6.log" 2>&1 &
    C6_FLOWER=$!
    sleep 2
    rec_start c6
    # 焦点还给 testapp 输入框（flower 抢过）
    timeout 10 "$DIST_BIN/virtpoint" move 540 80 1280 720 2>/dev/null || true
    timeout 10 "$DIST_BIN/virtpoint" click left 2>/dev/null || true
    sleep 0.5
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
    sleep 1.2
    WAYLAND_DISPLAY="$CAGE_SOCK" grim "$OUT_DIR/c6-top-center.png" 2>"$LOG_DIR/grim-c6.log" || true
    sleep 0.3
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 2.5  # 进候选态（卡片可见，顶部居中）
    # 方向键选（用户报告过的失效回归）
    for c6k in Down Down; do
        call InjectKey "$c6k" true >/dev/null 2>&1 || true
        call InjectKey "$c6k" false >/dev/null 2>&1 || true
        sleep 0.3
    done
    # hover 扫射+点击（motion_absolute 落点随指针历史漂移——静态坐标不可靠）
    for c6y in 120 160 200 240 280 320 360 400; do
        timeout 10 "$DIST_BIN/virtpoint" move 640 "$c6y" 1280 720 2>/dev/null || true
        sleep 0.4
        if tail -n +$((c6_mark+1)) "$FCITX_LOG" | grep -aq 'hover-row: [01]'; then
            timeout 10 "$DIST_BIN/virtpoint" click left 2>/dev/null || true
            sleep 1.2
            break
        fi
    done
    c6_win="$(tail -n +$((c6_mark+1)) "$FCITX_LOG")"
    c6_layer="$(printf '%s' "$c6_win" | grep -ac 'layer surface created' || true)"
    c6_conf="$(printf '%s' "$c6_win" | grep -ac 'layer surface configured' || true)"
    c6_click="$(printf '%s' "$c6_win" | grep -ac 'mouse-click-row' || true)"
    c6_commit="$(printf '%s' "$c6_win" | grep -ac 'committed' || true)"
    # 隐藏后穿透：先点 flower 抢走焦点，再点 testapp 输入框（≈530,80，
    # 卡片出现过的区域）——被残留输入区挡住则焦点回不来
    timeout 10 "$DIST_BIN/virtpoint" move 128 108 1280 720 2>/dev/null || true
    timeout 10 "$DIST_BIN/virtpoint" click left 2>/dev/null || true
    sleep 0.5
    C6_FOCUSED_BEFORE=$(grep -ac 'focus-in' "$LOG_DIR/testapp-c6.log" || true)
    timeout 10 "$DIST_BIN/virtpoint" move 530 80 1280 720 2>/dev/null || true
    timeout 10 "$DIST_BIN/virtpoint" click left 2>/dev/null || true
    sleep 1
    C6_FOCUSED_AFTER=$(grep -ac 'focus-in' "$LOG_DIR/testapp-c6.log" || true)
    kill "$C6_PID" "$C6_FLOWER" 2>/dev/null || true
    rec_stop
    set_cfg "<{'PositionMode': <'auto'>, 'UIFont': <''>}>"
    back_to_idle
    if [ "$c6_layer" -ge 1 ] && [ "$c6_conf" -ge 1 ] && [ "$c6_click" -ge 1 ] && \
       [ "$c6_commit" -ge 1 ] && [ "$C6_FOCUSED_AFTER" -gt "$C6_FOCUSED_BEFORE" ]; then
        record c6-position-explicit pass "top 档：layer 就绪 + hover/点击/方向键闭环 + 隐藏后穿透（焦点 $C6_FOCUSED_BEFORE→$C6_FOCUSED_AFTER）" "rec-c6.mp4"
    else
        record c6-position-explicit fail "layer=$c6_layer conf=$c6_conf click=$c6_click commit=$c6_commit 焦点 $C6_FOCUSED_BEFORE→$C6_FOCUSED_AFTER" "rec-c6.mp4"
    fi
else
    record c6-position-explicit pass "（跳过：无 virtpoint/录屏环境）"
fi

# c7 chromium 多幕（矩形时机 + 上屏继承 + classicui 抢槽）：
# 幕1 处女字段首录（新契约首下跟随或一次回退均合法）→ Enter 上屏
# 幕2 不动光标直接录——popup 重建须继承上屏后的新鲜矩形（跟随，零新 layer）
# 幕3 切 pinyin 打字让 classicui 建自己的 popup（抢定位槽）→ Escape →
#      再录——我们 show 重建重夺槽位。位置由截图视觉复核（c7-*.png）
if [ -n "${CAGE_SOCK:-}" ] && command -v chromium >/dev/null 2>&1; then
    set_cfg "<{'PositionMode': <'auto'>}>"
    sleep 0.5
    cat >/tmp/c7.html <<'HTML'
<!doctype html><html><body style="margin:0">
<input id="q" autofocus style="position:absolute;left:0;top:0;width:100%;height:100%;font-size:32px;border:8px solid #d00" placeholder="type here">
</body></html>
HTML
    pkill -f "chrome-c7" 2>/dev/null || true
    sleep 2
    c7_mark=$(wc -l < "$FCITX_LOG")
    chromium --ozone-platform=wayland --class=webapp-c7 --enable-wayland-ime \
        --no-first-run --disable-gpu --no-sandbox --disable-dev-shm-usage \
        --user-data-dir=/tmp/chrome-c7 file:///tmp/c7.html \
        >"$LOG_DIR/chromium-c7.log" 2>&1 &
    C7_PID=$!
    sleep 10
    rec_start c7
    # 幕1：点击字段 → 录音 → 上屏
    timeout 10 "$DIST_BIN/virtpoint" move 300 420 1280 720 2>/dev/null || true
    timeout 10 "$DIST_BIN/virtpoint" click left 2>/dev/null || true
    sleep 0.8
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
    sleep 1.2
    WAYLAND_DISPLAY="$CAGE_SOCK" grim "$OUT_DIR/c7-s1.png" 2>"$LOG_DIR/grim-c7.log" || true
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 2
    call SimulateKey "Return" true >/dev/null 2>&1 || true
    call SimulateKey "Return" false >/dev/null 2>&1 || true
    sleep 1.5
    # 幕2：不动光标直接录（继承矩形）
    c7_m2=$(wc -l < "$FCITX_LOG")
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
    sleep 1.2
    WAYLAND_DISPLAY="$CAGE_SOCK" grim "$OUT_DIR/c7-s2.png" 2>>"$LOG_DIR/grim-c7.log" || true
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 2
    call SimulateKey "Return" true >/dev/null 2>&1 || true
    call SimulateKey "Return" false >/dev/null 2>&1 || true
    sleep 1.5
    # 幕3：pinyin 抢槽 → 再录（重建重夺）
    timeout 30 gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.SetCurrentIM "pinyin" >/dev/null 2>&1 || true
    sleep 0.5
    for c7_k in N I H A O; do
        call InjectKey "$c7_k" true >/dev/null 2>&1 || true
        call InjectKey "$c7_k" false >/dev/null 2>&1 || true
        sleep 0.25
    done
    sleep 1.2
    WAYLAND_DISPLAY="$CAGE_SOCK" grim "$OUT_DIR/c7-classicui.png" 2>>"$LOG_DIR/grim-c7.log" || true
    call InjectKey "Escape" true >/dev/null 2>&1 || true
    call InjectKey "Escape" false >/dev/null 2>&1 || true
    timeout 30 gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.SetCurrentIM "keyboard-us" >/dev/null 2>&1 || true
    sleep 0.8
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
    sleep 1.2
    WAYLAND_DISPLAY="$CAGE_SOCK" grim "$OUT_DIR/c7-s3.png" 2>>"$LOG_DIR/grim-c7.log" || true
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 2
    call SimulateKey "Return" true >/dev/null 2>&1 || true
    call SimulateKey "Return" false >/dev/null 2>&1 || true
    sleep 1.5
    pkill -f "chrome-c7" 2>/dev/null || true
    sleep 1
    rec_stop
    back_to_idle
    c7_win="$(tail -n +$((c7_mark+1)) "$FCITX_LOG")"
    c7_w2="$(tail -n +$((c7_m2+1)) "$FCITX_LOG")"
    c7_commit="$(printf '%s' "$c7_win" | grep -ac '新鲜光标矩形' || true)"
    c7_follow2="$(printf '%s' "$c7_w2" | grep -ac '重夺定位槽' || true)"
    c7_nolayer2="$(printf '%s' "$c7_w2" | grep -ac 'layer surface created' || true)"
    c7_rebuild="$(printf '%s' "$c7_win" | grep -ac '重夺定位槽' || true)"
    c7_detach="$(printf '%s' "$c7_win" | grep -ac 'unmap+销毁' || true)"
    c7_shots=0
    for f in c7-s1.png c7-s2.png c7-classicui.png c7-s3.png; do
        [ -s "$OUT_DIR/$f" ] && c7_shots=$((c7_shots+1))
    done
    if [ "$c7_commit" -ge 1 ] && [ "$c7_follow2" -ge 1 ] && [ "$c7_nolayer2" -eq 0 ] && \
       [ "$c7_rebuild" -ge 3 ] && [ "$c7_detach" -ge 2 ] && [ "$c7_shots" -ge 4 ]; then
        record c7-chromium-follow pass "chromium 三幕：上屏记账 ×$c7_commit + 幕2 跟随（零回退）+ 抢槽后重建 ×$c7_rebuild（位置视觉复核 c7-*.png）" "rec-c7.mp4"
    else
        record c7-chromium-follow fail "commit=$c7_commit follow2=$c7_follow2 newlayer2=$c7_nolayer2 rebuild=$c7_rebuild detach=$c7_detach shots=$c7_shots"
    fi
else
    record c7-chromium-follow pass "（跳过：无 chromium/录屏）"
fi

# c8 GTK 光标重跟随（classicui 抢占定位槽复现）：两次录音（A→B 两点），
# 中间 pinyin 打字让 classicui 建自己的 popup（smithay 单槽 last-create-wins）
# → 我们 show 每次重建重夺槽位。断言：hide 销毁 + show 重建 + 真实矩形
if [ -n "${CAGE_SOCK:-}" ] && [ -x "$DIST_BIN/$TESTAPP" ] && [ -x "$DIST_BIN/virtpoint" ]; then
    set_cfg "<{'PositionMode': <'auto'>}>"
    sleep 0.5
    c8_mark=$(wc -l < "$FCITX_LOG")
    "$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-c8.log" 2>&1 &
    C8_PID=$!
    sleep 2
    rec_start c8
    # 光标 A 点（输入框左侧）→ 录音 1
    timeout 10 "$DIST_BIN/virtpoint" move 540 80 1280 720 2>/dev/null || true
    timeout 10 "$DIST_BIN/virtpoint" click left 2>/dev/null || true
    sleep 1.6  # GTK 焦点报文从容到达 → sawRealRect_ 置位 → 探针自跳过
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
    sleep 1.2
    WAYLAND_DISPLAY="$CAGE_SOCK" grim "$OUT_DIR/c8-s1.png" 2>"$LOG_DIR/grim-c8.log" || true
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 2
    call SimulateKey "Return" true >/dev/null 2>&1 || true
    call SimulateKey "Return" false >/dev/null 2>&1 || true
    sleep 1.5
    # classicui 抢槽：切 pinyin 打字（字母必须走 InjectKey——拼音引擎才看得见）
    timeout 30 gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.SetCurrentIM "pinyin" >/dev/null 2>&1 || true
    sleep 0.5
    for c8_k in N N H H; do
        call InjectKey "$c8_k" true >/dev/null 2>&1 || true
        call InjectKey "$c8_k" false >/dev/null 2>&1 || true
        sleep 0.25
    done
    sleep 1
    call InjectKey "Escape" true >/dev/null 2>&1 || true
    call InjectKey "Escape" false >/dev/null 2>&1 || true
    timeout 30 gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.SetCurrentIM "keyboard-us" >/dev/null 2>&1 || true
    sleep 0.8
    # 光标 B 点（右侧）→ 录音 2（重建 popup 贴新光标）
    timeout 10 "$DIST_BIN/virtpoint" move 700 80 1280 720 2>/dev/null || true
    timeout 10 "$DIST_BIN/virtpoint" click left 2>/dev/null || true
    sleep 0.8
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
    sleep 1.2
    WAYLAND_DISPLAY="$CAGE_SOCK" grim "$OUT_DIR/c8-s2.png" 2>>"$LOG_DIR/grim-c8.log" || true
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 2
    call SimulateKey "Return" true >/dev/null 2>&1 || true
    call SimulateKey "Return" false >/dev/null 2>&1 || true
    sleep 1.5
    kill "$C8_PID" 2>/dev/null || true
    rec_stop
    back_to_idle
    c8_win="$(tail -n +$((c8_mark+1)) "$FCITX_LOG")"
    c8_detach="$(printf '%s' "$c8_win" | grep -ac 'popup 已 unmap+销毁' || true)"
    c8_rebuild="$(printf '%s' "$c8_win" | grep -ac '重建：重夺定位槽' || true)"
    c8_real="$(printf '%s' "$c8_win" | grep -ac '收到真实光标矩形' || true)"
    if [ "$c8_detach" -ge 2 ] && [ "$c8_rebuild" -ge 1 ] && [ "$c8_real" -ge 1 ]; then
        record c8-refollow-gtk pass "GTK 两轮录音：hide 释放槽 ×$c8_detach + show 重建 ×$c8_rebuild + 真实矩形（位置视觉复核 c8-s1/2）" "rec-c8.mp4"
    else
        record c8-refollow-gtk fail "detach=$c8_detach rebuild=$c8_rebuild realrect=$c8_real"
    fi
else
    record c8-refollow-gtk pass "（跳过：无录屏/测试应用）"
fi

# c9 首按跟随+探针：处女字段首下即跟随（零回退+无残留空格）→ 上屏 →
# 焦点切走再切回 → 再录（探针+矩形重报）
if [ -n "${CAGE_SOCK:-}" ] && [ -x "$DIST_BIN/$TESTAPP" ] && [ -x "$DIST_BIN/virtpoint" ] && \
   command -v weston-flower >/dev/null 2>&1; then
    set_cfg "<{'PositionMode': <'auto'>}>"
    sleep 0.5
    c9_mark=$(wc -l < "$FCITX_LOG")
    "$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-c9.log" 2>&1 &
    C9_PID=$!
    weston-flower >"$LOG_DIR/flower-c9.log" 2>&1 &
    C9_FLOWER=$!
    sleep 2
    rec_start c9
    timeout 10 "$DIST_BIN/virtpoint" move 540 80 1280 720 2>/dev/null || true
    timeout 10 "$DIST_BIN/virtpoint" click left 2>/dev/null || true
    sleep 0.8
    # 轮 1：处女字段首录（首下即跟随）
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
    sleep 1.2
    WAYLAND_DISPLAY="$CAGE_SOCK" grim "$OUT_DIR/c9-first-press.png" 2>"$LOG_DIR/grim-c9.log" || true
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 2
    call SimulateKey "Return" true >/dev/null 2>&1 || true
    call SimulateKey "Return" false >/dev/null 2>&1 || true
    sleep 1.5
    # 焦点切走（flower）再切回
    timeout 10 "$DIST_BIN/virtpoint" move 128 108 1280 720 2>/dev/null || true
    timeout 10 "$DIST_BIN/virtpoint" click left 2>/dev/null || true
    sleep 1
    timeout 10 "$DIST_BIN/virtpoint" move 540 80 1280 720 2>/dev/null || true
    timeout 10 "$DIST_BIN/virtpoint" click left 2>/dev/null || true
    sleep 1
    # 轮 2：重聚焦首录
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
    sleep 1.2
    WAYLAND_DISPLAY="$CAGE_SOCK" grim "$OUT_DIR/c9-refocus.png" 2>>"$LOG_DIR/grim-c9.log" || true
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 2
    call SimulateKey "Return" true >/dev/null 2>&1 || true
    call SimulateKey "Return" false >/dev/null 2>&1 || true
    sleep 1.5
    kill "$C9_PID" "$C9_FLOWER" 2>/dev/null || true
    rec_stop
    back_to_idle
    c9_win="$(tail -n +$((c9_mark+1)) "$FCITX_LOG")"
    c9_probe="$(printf '%s' "$c9_win" | grep -ac '探针' || true)"
    c9_rect="$(printf '%s' "$c9_win" | grep -ac 'text_input_rectangle' || true)"
    c9_rebuild="$(printf '%s' "$c9_win" | grep -ac '重夺定位槽' || true)"
    c9_nofallback="$(printf '%s' "$c9_win" | grep -ac 'layer 模式回退' || true)"
    c9_lead=$(grep -ac '"text":" "' "$LOG_DIR/testapp-c9.log" || true)
    if [ "$c9_nofallback" -eq 0 ] && [ "$c9_rebuild" -ge 1 ] && [ "$c9_rect" -ge 2 ] && \
       [ "$c9_lead" -eq 0 ]; then
        record c9-first-press pass "首下即跟随（零回退+无残留空格）+ 矩形事件 ×$c9_rect（探针 ×$c9_probe；视觉复核 c9-*.png）" "rec-c9.mp4"
    else
        record c9-first-press fail "fallback=$c9_nofallback rebuild=$c9_rebuild rect=$c9_rect lead_space=$c9_lead"
    fi
else
    record c9-first-press pass "（跳过：无录屏/测试应用）"
fi

# c10 跨应用首聚：A（GTK）建立跟随 → 首次聚焦 B（chromium）输入框 → B 的
# 第一个语音会话（show 无知识暂缓二次探测）→ B 第二个会话必须跟随
if [ -n "${CAGE_SOCK:-}" ] && command -v chromium >/dev/null 2>&1 && [ -x "$DIST_BIN/$TESTAPP" ]; then
    set_cfg "<{'PositionMode': <'auto'>}>"
    sleep 0.5
    "$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-c10.log" 2>&1 &
    C10_A=$!
    sleep 2
    timeout 10 "$DIST_BIN/virtpoint" move 540 80 1280 720 2>/dev/null || true
    timeout 10 "$DIST_BIN/virtpoint" click left 2>/dev/null || true
    sleep 1.6
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
    sleep 1.2
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 2
    call SimulateKey "Return" true >/dev/null 2>&1 || true
    call SimulateKey "Return" false >/dev/null 2>&1 || true
    sleep 1.5
    kill "$C10_A" 2>/dev/null || true
    sleep 1
    c10_m1=$(wc -l < "$FCITX_LOG")
    chromium --ozone-platform=wayland --class=webapp-c10 --enable-wayland-ime \
        --no-first-run --disable-gpu --no-sandbox --disable-dev-shm-usage \
        --user-data-dir=/tmp/chrome-c10 file:///tmp/c7.html \
        >"$LOG_DIR/chromium-c10.log" 2>&1 &
    C10_B=$!
    sleep 10
    rec_start c10
    timeout 10 "$DIST_BIN/virtpoint" move 300 420 1280 720 2>/dev/null || true
    timeout 10 "$DIST_BIN/virtpoint" click left 2>/dev/null || true
    sleep 1
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
    sleep 1.2
    WAYLAND_DISPLAY="$CAGE_SOCK" grim "$OUT_DIR/c10-cross-first.png" 2>"$LOG_DIR/grim-c10.log" || true
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 2
    call SimulateKey "Return" true >/dev/null 2>&1 || true
    call SimulateKey "Return" false >/dev/null 2>&1 || true
    sleep 1.5
    c10_m2=$(wc -l < "$FCITX_LOG")
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
    sleep 1.2
    WAYLAND_DISPLAY="$CAGE_SOCK" grim "$OUT_DIR/c10-cross-second.png" 2>>"$LOG_DIR/grim-c10.log" || true
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 2
    call SimulateKey "Return" true >/dev/null 2>&1 || true
    call SimulateKey "Return" false >/dev/null 2>&1 || true
    sleep 1.5
    pkill -f "chrome-c10" 2>/dev/null || true
    sleep 1
    rec_stop
    back_to_idle
    c10_w1="$(tail -n +$((c10_m1+1)) "$FCITX_LOG")"
    c10_w2="$(tail -n +$((c10_m2+1)) "$FCITX_LOG")"
    c10_defer="$(printf '%s' "$c10_w1" | grep -ac '知识回退暂缓' || true)"
    c10_rect="$(printf '%s' "$c10_w1" | grep -ac 'text_input_rectangle' || true)"
    c10_switch="$(printf '%s' "$c10_w1" | grep -ac '切 layer 底部' || true)"
    c10_follow2="$(printf '%s' "$c10_w2" | grep -ac '重夺定位槽' || true)"
    c10_nolayer2="$(printf '%s' "$c10_w2" | grep -ac 'layer surface created' || true)"
    if [ "$c10_rect" -ge 1 ] || [ "$c10_defer" -ge 1 ] || [ "$c10_switch" -ge 1 ]; then
        if [ "$c10_follow2" -ge 1 ] && [ "$c10_nolayer2" -eq 0 ]; then
            record c10-cross-app pass "跨应用首聚：首轮信号 ✓（矩形 ×$c10_rect / 暂缓 ×$c10_defer），次轮跟随 ✓（视觉复核 c10-cross-*.png）" "rec-c10.mp4"
        else
            record c10-cross-app fail "首轮 ✓ 但次轮 follow2=$c10_follow2 newlayer2=$c10_nolayer2"
        fi
    else
        record c10-cross-app fail "首轮无任何信号 defer=$c10_defer rect=$c10_rect switch=$c10_switch"
    fi
else
    record c10-cross-app pass "（跳过：无 chromium/录屏）"
fi

# c11 连续听写跟随（"迟一步"修复验证）：三轮全自动，上屏后注入 Left+Right
# 微移逼应用按真实光标重报矩形。断言微移 ×3 + 重建 ×3（视觉复核 c11-s*.png）
if [ -n "${CAGE_SOCK:-}" ] && [ -x "$DIST_BIN/$TESTAPP" ] && [ -x "$DIST_BIN/virtpoint" ]; then
    set_cfg "<{'PositionMode': <'auto'>}>"
    sleep 0.5
    c11_mark=$(wc -l < "$FCITX_LOG")
    "$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-c11.log" 2>&1 &
    C11_PID=$!
    sleep 2
    rec_start c11
    timeout 10 "$DIST_BIN/virtpoint" move 540 80 1280 720 2>/dev/null || true
    timeout 10 "$DIST_BIN/virtpoint" click left 2>/dev/null || true
    sleep 0.8
    for c11_round in 1 2 3; do
        call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
        sleep 1.2
        WAYLAND_DISPLAY="$CAGE_SOCK" grim "$OUT_DIR/c11-s$c11_round.png" 2>>"$LOG_DIR/grim-c11.log" || true
        call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
        sleep 2
        call SimulateKey "Return" true >/dev/null 2>&1 || true
        call SimulateKey "Return" false >/dev/null 2>&1 || true
        sleep 1.8
    done
    kill "$C11_PID" 2>/dev/null || true
    rec_stop
    back_to_idle
    c11_win="$(tail -n +$((c11_mark+1)) "$FCITX_LOG")"
    c11_nudge="$(printf '%s' "$c11_win" | grep -ac '光标微移已注入' || true)"
    c11_rebuild="$(printf '%s' "$c11_win" | grep -ac '重夺定位槽' || true)"
    c11_shots=0
    for i in 1 2 3; do [ -s "$OUT_DIR/c11-s$i.png" ] && c11_shots=$((c11_shots+1)); done
    if [ "$c11_nudge" -ge 3 ] && [ "$c11_rebuild" -ge 3 ] && [ "$c11_shots" -eq 3 ]; then
        record c11-dictation pass "三轮连续听写：微移 ×$c11_nudge + 重建 ×$c11_rebuild（视觉复核 c11-s1/2/3）" "rec-c11.mp4"
    else
        record c11-dictation fail "nudge=$c11_nudge rebuild=$c11_rebuild shots=$c11_shots"
    fi
else
    record c11-dictation pass "（跳过：无录屏/测试应用）"
fi

# c12 字体跟随（classicui Font → fontconfig → Dart 加载）
printf 'Font="Noto Sans CJK SC 12"\n' >> /home/testuser/.config/fcitx5/conf/classicui.conf 2>/dev/null || true
set_cfg "<{'StreamingEnabled': <'True'>}>"
sleep 2
if grep -aq "UI 字体 →" "$FCITX_LOG" && grep -aq "ui-font:" "$FCITX_LOG"; then
    record c12-font pass "字体链路（$(grep -a 'ui-font:' "$FCITX_LOG" | tail -1 | sed 's/.*ui-font: //')）"
else
    record c12-font fail "字体链路未通（检查 fontconfig/消息日志）"
fi

# c13 Sherpa 流式+尾音完整（模型挂载才跑）：虚拟麦喂 wav，播完立刻松键
# ——断言 partial 流过 + final 含尾段（drain 生效，松键瞬间尾音不丢）
if [ -d "${AIINPUT_SHERPA_MODEL_DIR:-/nonexistent}" ] && [ -n "${CAGE_SOCK:-}" ]; then
    set_cfg "<{'AsrEngine': <'Sherpa'>}>"
    sleep 0.5
    "$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-c13.log" 2>&1 &
    C13_PID=$!
    sleep 2
    WAV=/samples/中文测试-16k.wav
    [ -f "$WAV" ] || WAV=$(ls /samples/*.wav 2>/dev/null | head -1 || true)
    c13_mark=$(wc -l < "$FCITX_LOG")
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
    sleep 0.6
    [ -n "$WAV" ] && play_to_mic "$WAV" &
    wait $! 2>/dev/null || true
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true  # 喂完立刻松
    sleep 3
    c13_win="$(tail -n +$((c13_mark+1)) "$FCITX_LOG")"
    c13_partial="$(printf '%s' "$c13_win" | grep -a "\[ui\] partial" | tail -1 | sed 's/.*partial: //' || true)"
    c13_final="$(printf '%s' "$c13_win" | grep -aE "\[ui\] (candidates|committed|result)" | tail -1 | sed 's/.*: //' || true)"
    kill "$C13_PID" 2>/dev/null || true
    set_cfg "<{'AsrEngine': <'Dummy'>}>"
    back_to_idle
    if [ -n "$c13_partial" ] && printf '%s' "$c13_final" | grep -q '语音测试'; then
        record c13-sherpa pass "流式 partial「$c13_partial」+ 尾音完整 final「$c13_final」"
    else
        record c13-sherpa fail "partial「$c13_partial」final「$c13_final」（尾段丢？模型/日志检查）"
    fi
else
    record c13-sherpa pass "（跳过：无模型/音频环境）"
fi

# c14 zipformer 双架构（宿主机回归：启动前置曾只认 paraformer 固定文件名，
# epoch 命名的 zipformer 被误报缺失；目录切换后 recognizer 必须重建）
if [ -d "/models/sherpa-zipformer" ]; then
    set_cfg "<{'AsrEngine': <'Sherpa'>, 'SherpaModelDir': <'/models/sherpa-zipformer'>}>"
    sleep 0.5
    "$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-c14.log" 2>&1 &
    C14_PID=$!
    sleep 2
    WAV=/samples/中文测试-16k.wav
    [ -f "$WAV" ] || WAV=$(ls /samples/*.wav 2>/dev/null | head -1 || true)
    c14_mark=$(wc -l < "$FCITX_LOG")
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true; sleep 0.8
    [ -n "$WAV" ] && play_to_mic "$WAV" &
    C14_PLAY=$!
    sleep 6
    wait "$C14_PLAY" 2>/dev/null || true
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 3
    c14_win="$(tail -n +$((c14_mark+1)) "$FCITX_LOG")"
    c14_final="$(printf '%s' "$c14_win" | grep -aE "\[ui\] (candidates|committed|result)" | tail -1 | sed 's/.*: //' || true)"
    kill "$C14_PID" 2>/dev/null || true
    set_cfg "<{'AsrEngine': <'Dummy'>, 'SherpaModelDir': <''>}>"
    back_to_idle
    if printf '%s' "$c14_win" | grep -aq "zipformer transducer" && [ -n "$c14_final" ] && \
       printf '%s' "$c14_win" | grep -aq "重建 recognizer" && \
       ! printf '%s' "$c14_win" | grep -aq "模型缺失.*sherpa-zipformer"; then
        record c14-zipformer pass "zipformer 启动+识别+缓存重建：final「$c14_final」"
    else
        record c14-zipformer fail "未正确启动（final「$c14_final」；transducer/重建/缺失日志检查未全过）"
    fi
else
    record c14-zipformer pass "（跳过：zipformer 模型未挂载）"
fi

# c15 SenseVoice 松手重识别（final 走离线模型：带标点，混说质量档）
if [ -d "/models/sensevoice" ] && [ -d "/models/sherpa-zipformer" ]; then
    set_cfg "<{'AsrEngine': <'Sherpa'>, 'SherpaModelDir': <'/models/sherpa-zipformer'>, 'SenseVoiceDir': <'/models/sensevoice'>}>"
    sleep 0.5
    "$DIST_BIN/$TESTAPP" >"$LOG_DIR/testapp-c15.log" 2>&1 &
    C15_PID=$!
    sleep 2
    WAV=/samples/中文测试-16k.wav
    [ -f "$WAV" ] || WAV=$(ls /samples/*.wav 2>/dev/null | head -1 || true)
    c15_mark=$(wc -l < "$FCITX_LOG")
    call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true; sleep 0.8
    [ -n "$WAV" ] && play_to_mic "$WAV" &
    C15_PLAY=$!
    sleep 6
    wait "$C15_PLAY" 2>/dev/null || true
    call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
    sleep 3
    c15_win="$(tail -n +$((c15_mark+1)) "$FCITX_LOG")"
    c15_final="$(printf '%s' "$c15_win" | grep -aE "\[ui\] (candidates|committed|result)" | tail -1 | sed 's/.*: //' || true)"
    c15_sv="$(printf '%s' "$c15_win" | grep -ac "SenseVoice final" || true)"
    kill "$C15_PID" 2>/dev/null || true
    set_cfg "<{'AsrEngine': <'Dummy'>, 'SherpaModelDir': <''>, 'SenseVoiceDir': <''>}>"
    back_to_idle
    if [ "$c15_sv" -ge 1 ] && printf '%s' "$c15_final" | grep -q '。'; then
        record c15-sensevoice pass "final 走离线重识别（带标点）：「$c15_final」"
    else
        record c15-sensevoice fail "离线 final 未生效（final「$c15_final」，SenseVoice 日志 $c15_sv 次）"
    fi
else
    record c15-sensevoice pass "（跳过：sensevoice/zipformer 模型未挂载）"
fi
fi  # corner

# 停采样器并等它写出 summary
kill -TERM "$SAMPLER_PID" 2>/dev/null || true
for _ in $(seq 1 10); do
    kill -0 "$SAMPLER_PID" 2>/dev/null || break
    sleep 0.5
done

echo "== 用例执行完毕：$RESULTS"
