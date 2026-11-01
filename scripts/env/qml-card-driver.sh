#!/usr/bin/env bash
# QML 卡双显验证 driver v2（T9 容器验证）：testapp 的 IC 是
# clientSideInputPanel=true（InputPanel 不派给 UserInterface，候选窗由
# GTK IM 模块自绘——P4b 断言从 0.4.5 起测的就不是我们）。panel/* 派发
# 验证改用 ic-sim（D-Bus 前端 IC，clientSide=false）；语音卡用其 IC 的
# rect 驱动。镜像须带 quickshell（aiinput-qml-probe 系）。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

FCITX_LOG="$LOG_DIR/fcitx5.log"
DIST_BIN="${DIST_BIN:-/opt/dist/bin}"
call() { timeout 30 gdbus call --session --dest org.fcitx.Fcitx5 \
    --object-path /org/fcitx/AiInput \
    --method org.fcitx.AiInput.Test."$1" "${@:2}" 2>&1; }
shot() { WAYLAND_DISPLAY="$CAGE_SOCK" timeout 10 grim "$1" 2>/dev/null || true; }

echo "== 1) 等待 QML 卡 socket 连接"
for _ in $(seq 1 40); do
    grep -aq "QML 卡片已连接" "$FCITX_LOG" && break
    sleep 0.5
done
grep -aq "QML 卡片已连接" "$FCITX_LOG" && echo "✓ socket 已连接" || echo "✗ 卡片未连接"

echo "== 2) 背景窗口（视觉锚点）"
"$DIST_BIN/testapp-gtk" >"$LOG_DIR/testapp-qml.log" 2>&1 &
APP_PID=$!
timeout 10 "$DIST_BIN/virtpoint" move 540 80 1280 720 2>/dev/null || true
timeout 10 "$DIST_BIN/virtpoint" click left 2>/dev/null || true
sleep 1

echo "== 3) ic-sim IC 驱动：语音会话 → pinyin 候选（小写键防 spell 直通）"
( printf 'create t1 t1\nuse 1\nfocus-in\nrect 540 300 8 50\nsleep 400\n\
key Control_R press ctrl\nsleep 1600\n\
key Control_R release ctrl\nsleep 2600\n\
key Escape press\nkey Escape release\nsleep 600\n\
setim pinyin\nsleep 300\n\
key n press\nkey n release\nsleep 350\n\
key i press\nkey i release\nsleep 350\n\
key h press\nkey h release\nsleep 350\n\
key a press\nkey a release\nsleep 350\n\
key o press\nkey o release\nsleep 1800\n\
sleep 8000\n' | timeout 26 "$DIST_BIN/ic-sim" 2>>"$LOG_DIR/ic-sim.err" ) &
IC_PID=$!

# 时序对齐：rect+400ms 后 press → 450ms 阈值 → recording（~t+2.5s 截语音卡）
sleep 3
shot "$OUT_DIR/dual-voice.png"
# release→tail 400ms→asr dummy final→candidates（dummy LLM 即时）；Esc 取消后
# pinyin 5 键（~t+9.5s 起）——t+11s 截候选双显
sleep 5
shot "$OUT_DIR/dual-result.png"
sleep 4
shot "$OUT_DIR/dual-panel.png"
wait "$IC_PID" 2>/dev/null || true

echo "== 4) 证据汇总"
echo "-- update(component=1): $(grep -ac 'update(component=1' "$FCITX_LOG")"
grep -ao "sock->] panel[a-z/]*" "$FCITX_LOG" | sort | uniq -c
grep -a "CARD: ENV" "$FCITX_LOG" | grep -oE "method=[a-z/]+" | sort | uniq -c
kill "$APP_PID" 2>/dev/null || true
echo "== QML 卡验证完成"
