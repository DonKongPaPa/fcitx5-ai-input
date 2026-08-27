#!/usr/bin/env bash
# gtkscale 诊断驱动（一次性；CASE_DRIVER=/scripts/env/gtkscale-driver.sh 挂载）
# 问题：X 场景卡片不在光标旁（vision 基线：卡片落在应用窗左侧桌面，
# scale=2.0 偏移更大）——fcitx5-gtk 模块路径下 X 定位偏移的根因取证
# 链条四环（summary.txt 汇总，逐环有独立产物）：
#   A0 fcitx5-gtk 在位证据（包版本 + gtk4 immodule 可加载清单）
#   A2 模块上报 rect 的坐标空间：app 窗 X root 绝对几何（xwininfo）
#      vs addon 收到的 rect= 值（fcitx5.log）→ rect 含不含窗口原点
#   A3 卡片落点：卡片窗（root 的 OR 子窗）root 几何 vs caret 实际位置；
#      niri 侧窗口几何（niri msg）交叉验证 X root↔屏幕物理换算
#   B  无模块对照：unset GTK_IM_MODULE/XMODIFIERS 重跑 → 无 rect 无卡片，
#      证明 A 阶段 rect 确由 fcitx5-gtk 模块上报
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

DIST_BIN="${DIST_BIN:-/opt/dist/bin}"
SCALE="${NIRI_TEST_SCALE:-2.0}"
GDKS=$(python3 -c "print(int(float('$SCALE')))")
LOGW=$(python3 -c "print(int(1920/float('$SCALE')))")
LOGH=$(python3 -c "print(int(1080/float('$SCALE')))")
SUM="$OUT_DIR/summary.txt"
FCITX_LOG="$LOG_DIR/fcitx5.log"

call() { timeout 30 gdbus call --session --dest org.fcitx.Fcitx5 \
    --object-path /org/fcitx/AiInput \
    --method org.fcitx.AiInput.Test."$1" "${@:2}" 2>&1; }

say() { echo "$*" | tee -a "$SUM"; }
: >"$SUM"
say "== gtkscale 诊断 scale=$SCALE GDK_SCALE=$GDKS 逻辑输出 ${LOGW}x${LOGH} =="

# A0 模块在位
{
    echo "-- fcitx5-gtk 包 --"
    pacman -Qi fcitx5-gtk 2>/dev/null | sed -n '1,3p'
    echo "-- gtk4 immodules --"
    gtk-query-immodules-4.0 --list 2>/dev/null || ls /usr/lib/gtk-4.0/4.0.0/immodules/
} >>"$SUM" 2>&1

# A1 模块路径：X testapp（空框 caret 在 entry 左缘，位置确定性——X 路径
# 打字注入不可用：InjectKey 的 forwardKey 依赖 im 模块合成 X 键事件，
# 实测未到达 GTK（疑 send_event 被 GTK 丢弃），与定位验证无关）
LOG_MARK=$(wc -l <"$FCITX_LOG" 2>/dev/null || echo 0)
GDK_BACKEND=x11 GTK_IM_MODULE=fcitx GDK_SCALE=$GDKS TEST_TIMEOUT=300 \
    "$DIST_BIN/testapp-gtk" >"$LOG_DIR/gtkscale-app-a.log" 2>&1 &
sleep 3
timeout 10 "$DIST_BIN/virtpoint" move $((LOGW / 2)) 225 "$LOGW" "$LOGH" 2>/dev/null || true
timeout 10 "$DIST_BIN/virtpoint" click left 2>/dev/null || true
sleep 0.5

# A2 触发前几何：X root 侧 + niri 屏幕侧
niri msg windows >"$OUT_DIR/niri-windows-before.txt" 2>"$LOG_DIR/niri-msg.err" || true
niri msg outputs >"$OUT_DIR/niri-outputs.txt" 2>>"$LOG_DIR/niri-msg.err" || true
AWID="$(xprop -root _NET_ACTIVE_WINDOW 2>/dev/null | grep -oP 'window id # \K0x[0-9a-f]+' || true)"
say "活动 X 窗 id=$AWID"
[ -n "$AWID" ] && xwininfo -id "$AWID" -stats >"$OUT_DIR/xwininfo-app-before.txt" 2>&1 || true
xwininfo -root -tree >"$OUT_DIR/xwininfo-tree-before.txt" 2>&1 || true

# A3 触发语音会话 → 卡片取证
call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
sleep 1.2
call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
sleep 2.5
xwininfo -root -tree >"$OUT_DIR/xwininfo-tree-card.txt" 2>&1 || true
[ -n "$AWID" ] && xwininfo -id "$AWID" -stats >"$OUT_DIR/xwininfo-app-after.txt" 2>&1 || true
niri msg windows >"$OUT_DIR/niri-windows-card.txt" 2>>"$LOG_DIR/niri-msg.err" || true
CWID="$(tail -n +$((LOG_MARK + 1)) "$FCITX_LOG" | grep -aoP 'X OR 卡片窗 0x\K[0-9a-f]+' | head -1 || true)"
say "卡片窗 id=0x$CWID"
[ -n "$CWID" ] && xwininfo -id "0x$CWID" -stats >"$OUT_DIR/xwininfo-card.txt" 2>&1 || true
WAYLAND_DISPLAY="$CAGE_SOCK" grim "$OUT_DIR/gtkscale-$SCALE.png" 2>>"$LOG_DIR/grim.log" || true

tail -n +$((LOG_MARK + 1)) "$FCITX_LOG" \
    | grep -aE "X OR 卡片|X 错误|活动 X 窗|矩形溢出" >"$OUT_DIR/fcitx5-x-lines.txt" || true
say "-- addon X 日志（截选，全量见 fcitx5-x-lines.txt）--"
sed -n '1,10p' "$OUT_DIR/fcitx5-x-lines.txt" | tee -a "$SUM" || true

# A5 会话收尾
call SimulateKey "Return" true >/dev/null 2>&1 || true
sleep 0.1
call SimulateKey "Return" false >/dev/null 2>&1 || true
sleep 1.5
pkill -f testapp-gtk 2>/dev/null || true
sleep 1

# B 无模块对照
LOG_MARK_B=$(wc -l <"$FCITX_LOG" 2>/dev/null || echo 0)
env -u GTK_IM_MODULE -u XMODIFIERS -u QT_IM_MODULE \
    GDK_BACKEND=x11 GDK_SCALE=$GDKS TEST_TIMEOUT=120 \
    "$DIST_BIN/testapp-gtk" >"$LOG_DIR/gtkscale-app-b.log" 2>&1 &
sleep 3
timeout 10 "$DIST_BIN/virtpoint" move $((LOGW / 2)) 225 "$LOGW" "$LOGH" 2>/dev/null || true
timeout 10 "$DIST_BIN/virtpoint" click left 2>/dev/null || true
sleep 0.5
call SimulateKey "Control+Control_R" true >/dev/null 2>&1 || true
sleep 1.2
call SimulateKey "Control+Control_R" false >/dev/null 2>&1 || true
sleep 2
xwininfo -root -tree >"$OUT_DIR/xwininfo-tree-nomodule.txt" 2>&1 || true
B_CARD=$(tail -n +$((LOG_MARK_B + 1)) "$FCITX_LOG" | grep -ac "X OR 卡片窗" || true)
say "无模块对照：卡片窗日志数=$B_CARD（0 ⟹ A 阶段 rect 的唯一来源是 fcitx5-gtk 模块）"
pkill -f testapp-gtk 2>/dev/null || true

# C classicui 对照：同一 X 场景跑 pinyin+classicui 候选窗，实测其定位/缩放。
#    源码依据（fcitx5 xcbinputwindow.cpp/xcbui.cpp）：候选窗=root 的 OR 子窗、
#    x=cursorRect.left() 原样用、只钳 X 屏幕矩形（无父窗钳制）；窗口缩放=
#    Xft.dpi/96（isXWayland 时明确跳过逐屏 DPI 只认 Xft.dpi）
LOG_MARK_C=$(wc -l <"$FCITX_LOG" 2>/dev/null || echo 0)
GDK_BACKEND=x11 GTK_IM_MODULE=fcitx GDK_SCALE=$GDKS TEST_TIMEOUT=180 \
    "$DIST_BIN/testapp-gtk" >"$LOG_DIR/gtkscale-app-c.log" 2>&1 &
sleep 3
timeout 10 "$DIST_BIN/virtpoint" move $((LOGW / 2)) 225 "$LOGW" "$LOGH" 2>/dev/null || true
timeout 10 "$DIST_BIN/virtpoint" click left 2>/dev/null || true
sleep 0.5
# Xft.dpi=scale×96 喂给 classicui（RESOURCE_MANAGER 属性；无 xrdb 故用 xprop）
xprop -root -f RESOURCE_MANAGER 8s -set RESOURCE_MANAGER $'Xft.dpi:\t'"$((GDKS * 96))" || true
sleep 0.8
printf 'setim pinyin\n' | timeout 15 "$DIST_BIN/ic-sim" >>"$LOG_DIR/gtkscale-c-ic-sim.log" 2>&1 || true
sleep 0.5
for ch in n i h a o; do
    call InjectKey "$ch" true >/dev/null 2>&1 || true
    sleep 0.05
    call InjectKey "$ch" false >/dev/null 2>&1 || true
    sleep 0.1
done
sleep 1.2
xwininfo -root -tree >"$OUT_DIR/xwininfo-tree-classicui.txt" 2>&1 || true
CLWID="$(grep -oP '0x[0-9a-f]+ "Fcitx5 Input Window"' "$OUT_DIR/xwininfo-tree-classicui.txt" 2>/dev/null | grep -oP '^0x[0-9a-f]+' || true)"
[ -n "$CLWID" ] && xwininfo -id "$CLWID" -stats >"$OUT_DIR/xwininfo-classicui.txt" 2>&1 || true
AWID_C="$(xprop -root _NET_ACTIVE_WINDOW 2>/dev/null | grep -oP 'window id # \K0x[0-9a-f]+' || true)"
[ -n "$AWID_C" ] && xwininfo -id "$AWID_C" -stats >"$OUT_DIR/xwininfo-app-classicui.txt" 2>&1 || true
WAYLAND_DISPLAY="$CAGE_SOCK" grim "$OUT_DIR/gtkscale-classicui-$SCALE.png" 2>>"$LOG_DIR/grim.log" || true
say "classicui 对照：候选窗 id=$CLWID app=$AWID_C（几何行↓）"
[ -s "$OUT_DIR/xwininfo-classicui.txt" ] && grep -E "Absolute upper-left|^  Width|^  Height" "$OUT_DIR/xwininfo-classicui.txt" | tee -a "$SUM" || true
# 还原输入法并清理
printf 'setim keyboard-us\n' | timeout 15 "$DIST_BIN/ic-sim" >>"$LOG_DIR/gtkscale-c-ic-sim.log" 2>&1 || true
call InjectKey "Escape" true >/dev/null 2>&1 || true
sleep 0.05
call InjectKey "Escape" false >/dev/null 2>&1 || true
sleep 0.5
pkill -f testapp-gtk 2>/dev/null || true

say "== 诊断采集完成（scale=$SCALE）=="
