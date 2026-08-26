#!/usr/bin/env bash
# addon-test 驱动（容器内，无显示栈）：ic-sim 纯 D-Bus 造 IC 驱动状态机。
# 前置：dbus-run-session 内、fcitx5 已起（无合成器）、/usr 已装 dist。
# 与 e2e 的分工：这里只测会话逻辑（按键语义/看门狗/失焦/跨 IC/引擎流），
# ~40s；定位与渲染归 surface/e2e 容器。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

RESULTS="$OUT_DIR/case-results.jsonl"
: >"$RESULTS"
record() {
    jq -cn --arg id "$1" --arg status "$2" --arg note "$3" \
        '{id:$id,status:$status,expected:"",actual:$note,diff_note:$note,
          latency_ms:0,recording:""}' >>"$RESULTS"
    echo "   → $2 ($1)"
}
FCITX_LOG="$LOG_DIR/fcitx5.log"
call() { timeout 30 gdbus call --session --dest org.fcitx.Fcitx5 \
    --object-path /org/fcitx/AiInput \
    --method org.fcitx.AiInput.Test."$1" "${@:2}" 2>&1; }
set_cfg() {
    timeout 30 gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.SetConfig \
        "fcitx://config/addon/aiinput" "$1" >/dev/null 2>&1 || true
}
state_is() { case "$(call State 2>/dev/null || true)" in *"$1"*) return 0;; *) return 1;; esac; }
mark() { MARK=$(wc -l < "$FCITX_LOG"); }
win() { tail -n +$((MARK+1)) "$FCITX_LOG"; }
back_to_idle() {
    for _ in 1 2 3; do
        state_is idle && return 0
        printf 'key Control_R press ctrl\nkey Control_R release ctrl\n' | timeout 20 /usr/bin/ic-sim >/dev/null 2>&1 || true
        sleep 1.6
    done
    return 0
}
# 驱动当前 IC 的便捷封装：pipe 脚本进 ic-sim（每用例新建进程/IC）
sim() { printf '%s\n' "$@" | timeout 60 /usr/bin/ic-sim 2>>"$LOG_DIR/ic-sim.err"; }

echo "== A. addon 无显示状态机（ic-sim 驱动）"

# a1 模块加载 + 版本
if grep -aq "AiInput module loaded" "$FCITX_LOG"; then
    bin_ver=""
    for _ in $(seq 1 10); do
        bin_ver="$(call Version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
        [ -n "$bin_ver" ] && break
        sleep 0.5
    done
    [ -n "$bin_ver" ] && record a1-load pass "Module 加载 + Test 服务可用（v$bin_ver）" \
        || record a1-load fail "模块加载但 Test 服务不可用"
else
    record a1-load fail "未见 module loaded 日志"
fi

# a2 真实 D-Bus 键触发→录音→模态吞键→松开→候选→数字键选择→上屏
mark
OUT=$(sim 'create app-a' 'focus-in' 'key Control_R press ctrl' 'sleep 700' 'key x press' 'key x release' 'sleep 300' 'key Control_R release ctrl' 'sleep 2200' 'key 1 press' 'key 1 release' 'commit-wait 我们出去玩吧 6000')
echo "$OUT" >"$LOG_DIR/a2-ic-sim.log"
a2_notes=""
echo "$OUT" | grep -q "filtered=1" || a2_notes="录音中 x 未被吞（filtered=0）"
echo "$OUT" | grep -q "filtered=0" || a2_notes="${a2_notes:+$a2_notes；}候选态数字键未透传（filtered=1）"
W=$(win); echo "$W" > "$LOG_DIR/a2-journal.log"
echo "$W" | grep -aq "recording-start" || a2_notes="${a2_notes:+$a2_notes；}未进录音"
echo "$W" | grep -aq "candidates" || a2_notes="${a2_notes:+$a2_notes；}未出候选"
echo "$OUT" | grep -q "commit-ok" || a2_notes="${a2_notes:+$a2_notes；}无上屏"
[ -z "$a2_notes" ] && record a2-key-flow pass "真实 D-Bus 键全流程：触发→录音→吞键→候选→数字选择→CommitString" \
    || record a2-key-flow fail "$a2_notes"
back_to_idle

# a3 组合键取消 + 透传（Pressing 窗口内 s）
mark
OUT=$(sim 'create app-b' 'focus-in' 'key Control_R press ctrl' 'sleep 100' 'key s press' 'key s release' 'sleep 500')
echo "$OUT" >"$LOG_DIR/a3-ic-sim.log"
if echo "$OUT" | grep -q "key s p filtered=0" && state_is idle; then
    record a3-combo-passthrough pass "组合键：候选取消（idle）且 s 透传（filtered=0）"
else
    record a3-combo-passthrough fail "state=$(call State 2>/dev/null || true) out=$(echo "$OUT" | grep 'key s' | head -1)"
fi
back_to_idle

# a4 看门狗（MaxRecordingSec=10，按住不放）
set_cfg "<{'MaxRecordingSec': <'10'>}>"
sleep 0.5
mark
sim 'create app-c' 'focus-in' 'key Control_R press ctrl' 'sleep 12500' >"$LOG_DIR/a4-ic-sim.log" 2>&1 || true
sleep 1
W=$(win)
a4_ok=1; case "$(call State 2>/dev/null || true)" in *recording*) a4_ok=0;; esac
if echo "$W" | grep -aq "录音看门狗触发" && [ "$a4_ok" = 1 ]; then
    record a4-watchdog pass "无松开 10s 看门狗自动结束（无显示环境同样生效）"
else
    record a4-watchdog fail "journal=$(echo "$W" | grep -ac 看门狗 || true) state=$(call State 2>/dev/null || true)"
fi
set_cfg "<{'MaxRecordingSec': <'60'>}>"
back_to_idle

# a5 录音中失焦自愈
mark
sim 'create app-d' 'focus-in' 'key Control_R press ctrl' 'sleep 800' 'focus-out' 'sleep 2500' >"$LOG_DIR/a5-ic-sim.log" 2>&1 || true
W=$(win)
a5_ok=1; case "$(call State 2>/dev/null || true)" in *recording*) a5_ok=0;; esac
if echo "$W" | grep -aq "会话 IC 失焦——自动结束" && [ "$a5_ok" = 1 ]; then
    record a5-focusout pass "录音中 IC 失焦→自动结束识别"
else
    record a5-focusout fail "blur=$(echo "$W" | grep -ac 失焦 || true) state=$(call State 2>/dev/null || true)"
fi
back_to_idle

# a6 跨 IC 触发回收：A 停在候选态（焦点切走不清候选——focusOutWatcher 只管
# Recording/Pressing）→ 同进程内 B 聚焦夺焦 → B 触发=换目标回收旧会话。
# A/B 必须同 ic-sim 进程存活：分进程会销毁 A 的 IC 走死 IC 自愈路径
mark
OUT=$(sim 'create app-e' 'focus-in' 'key Control_R press ctrl' 'sleep 600' 'key Control_R release ctrl' 'sleep 2200' 'create app-f' 'focus-in' 'key Control_R press ctrl' 'sleep 600' 'key Control_R release ctrl' 'sleep 2500')
echo "$OUT" >"$LOG_DIR/a6-ic-sim.log"
W=$(win)
if echo "$W" | grep -aq "跨 IC 触发——回收旧会话" && echo "$W" | grep -aq "recording-start"; then
    record a6-cross-ic pass "候选残留下跨 IC 触发：旧会话回收+新会话启动"
else
    record a6-cross-ic fail "journal 缺回收/启动日志（$(echo "$W" | grep -ac '跨 IC' || true)）"
fi
back_to_idle

# a7 拼音组合→InputPanel（P4b：panel 管道端到端）。fcitx5 只把
# InputPanel 派发给唯一活跃 UI（uim updateSingleComponent 的 ui_），
# start-headless --disable=classicui,kimpanel 保障选中的是我们；
# keyboard-us 不产生组合——必须 setim pinyin 才有 component=0 可言
if [ -f /usr/share/fcitx5/addon/pinyin.conf ]; then
    mark
    OUT=$(sim 'create app-g' 'focus-in' 'setim pinyin' \
        'key n press' 'key n release' 'key i press' 'key i release' \
        'key h press' 'key h release' 'key a press' 'key a release' \
        'key o press' 'key o release' 'sleep 300' \
        'key space press' 'key space release' \
        'commit-wait 你好 5000' 'setim keyboard-us')
    echo "$OUT" >"$LOG_DIR/a7-ic-sim.log"
    W=$(win); echo "$W" > "$LOG_DIR/a7-journal.log"
    a7_notes=""
    echo "$W" | grep -aq "update(component=0" || a7_notes="InputPanel 更新未到达 UI 层"
    echo "$OUT" | grep -q "setim pinyin ok" || a7_notes="${a7_notes:+$a7_notes；}setim 失败"
    echo "$OUT" | grep -q "commit-ok" || a7_notes="${a7_notes:+$a7_notes；}拼音候选未上屏"
    [ -z "$a7_notes" ] && record a7-im-panel pass "拼音组合→update(component=0) 到 UI 层→候选上屏" \
        || record a7-im-panel fail "$a7_notes"
else
    record a7-im-panel skip "镜像无 pinyin addon（重建 base 镜像后生效）"
fi
back_to_idle

echo "== addon-driver 完毕：$RESULTS"
