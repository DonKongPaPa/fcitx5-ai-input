#!/usr/bin/env bash
# addon-test 环境容器内编排：无合成器——dbus-run-session + fcitx5 + ic-sim。
# 与 start-niri.sh 同款结构（MODE=case 移交驱动器），但没有任何显示栈：
# 会话逻辑/按键语义/看门狗在此测；定位与渲染归 surface/e2e 容器。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

MODE="${MODE:-case}"

# 1. fcitx5 直起（dbus 前端独立工作；wayland/xcb 模块无显示时各自让位，
#    我们的 popup 走 headless 无处挂分支——仅记日志不影响会话）
#    --disable classicui/kimpanel：InputPanel 只派发给唯一活跃 UI
#    （uim updateSingleComponent 只看 ui_），禁竞争者才是确定性选中我们
fcitx5 -d --replace --disable=classicui,kimpanel >"$LOG_DIR/fcitx5.log" 2>&1
for _ in $(seq 1 40); do
    busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 && break
    sleep 0.5
done
busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 || {
    echo "fcitx5 dbus 名未就绪"; tail -20 "$LOG_DIR/fcitx5.log" >&2; exit 1
}
echo "fcitx5 就绪（无显示）"

if [ "$MODE" = "case" ]; then
    bash "$SCRIPT_DIR/addon-driver.sh"
    exit 0
fi
exec bash
