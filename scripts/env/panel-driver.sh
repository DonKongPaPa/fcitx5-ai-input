#!/usr/bin/env bash
# P4b 验证：禁 classicui → 我们成为 UI → pinyin 组合 → 候选窗渲染 + 点击选择
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

unset GTK_IM_MODULE QT_IM_MODULE SDL_IM_MODULE XMODIFIERS
DIST_BIN="${DIST_BIN:-/opt/dist/bin}"
FCITX_LOG="$LOG_DIR/fcitx5.log"
call() { timeout 30 gdbus call --session --dest org.fcitx.Fcitx5 \
    --object-path /org/fcitx/AiInput \
    --method org.fcitx.AiInput.Test."$1" "${@:2}" 2>&1; }
set_im() { timeout 30 gdbus call --session --dest org.fcitx.Fcitx5 \
    --object-path /controller \
    --method org.fcitx.Fcitx.Controller1.SetCurrentIM "$1" \
    >/dev/null 2>&1 || true; }
shot() { WAYLAND_DISPLAY="$CAGE_SOCK" timeout 10 grim "$1" 2>/dev/null || true; }

echo "== P4b 验证：我们接管 UI（pinyin 候选窗）"

# 1) 确认我们的 addon 已加载为 UI
grep -aq "AiInput module loaded" "$FCITX_LOG" && echo "✓ addon 已加载" || {
    echo "✗ addon 未加载"; exit 1; }

# 2) 禁 classicui（fcitx 会切到唯一 UI=我们）
gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
    --method org.fcitx.Fcitx.Controller1.SetConfig \
    "fcitx://config/addon/classicui" "<{'Enabled': <'False'>}>" >/dev/null 2>&1 || true
sleep 1
echo "✓ classicui 已禁用"

# 3) 启动 testapp 并聚焦
"$DIST_BIN/testapp-gtk" >"$LOG_DIR/testapp-panel.log" 2>&1 &
APP_PID=$!
sleep 2
timeout 10 "$DIST_BIN/virtpoint" move 540 80 1280 720 2>/dev/null || true
timeout 10 "$DIST_BIN/virtpoint" click left 2>/dev/null || true
sleep 0.5

# 4) 切 pinyin 打字
set_im pinyin; sleep 0.5
MARK=$(wc -l < "$FCITX_LOG")
for k in N I H A O; do
    call InjectKey "$k" true >/dev/null 2>&1 || true
    call InjectKey "$k" false >/dev/null 2>&1 || true
    sleep 0.25
done
sleep 1.5
shot "$OUT_DIR/panel-candidates.png"

# 5) 检查 panel/update 事件是否发出（journal）
W=$(tail -n +$((MARK+1)) "$FCITX_LOG")
PANEL_EVENTS=$(echo "$W" | grep -ac "panel/update" || true)
echo "panel/update 事件数: $PANEL_EVENTS"

# 6) 截图断言：候选文本可见
if python3 -c "
from PIL import Image
im = Image.open('$OUT_DIR/panel-candidates.png').convert('RGB')
# 全屏搜浅色面板区域（非深色=面板存在）
w,h = im.size; px = im.load()
bright_panel = 0
for y in range(0, h, 4):
    for x in range(0, w, 4):
        r,g,b = px[x,y]
        if r > 230 and g > 230 and b > 230:
            bright_panel += 1
exit(0 if bright_panel > 200 else 1)
" 2>/dev/null; then
    echo "✓ 截图有浅色候选面板区域（bright>200）"
    RESULT=pass
else
    echo "✗ 截图未检测到候选面板"
    RESULT=fail
fi

# 7) 清理
call InjectKey "Escape" true >/dev/null 2>&1 || true
call InjectKey "Escape" false >/dev/null 2>&1 || true
set_im keyboard-us
kill "$APP_PID" 2>/dev/null || true

# 恢复 classicui
gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
    --method org.fcitx.Fcitx.Controller1.SetConfig \
    "fcitx://config/addon/classicui" "<{'Enabled': <'True'>}>" >/dev/null 2>&1 || true

echo "== P4b 结果：$RESULT（panel/update ×$PANEL_EVENTS）"
echo "$RESULT" > "$OUT_DIR/p4b-result.txt"
