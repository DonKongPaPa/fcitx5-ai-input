#!/usr/bin/env bash
# UI 选择诊断 driver v2：竞争者经全局 config 的 [Behavior] DisabledAddons
# 禁用（用户级 addon/*.conf 的 Enabled=False 实测不生效）。driver 自身已在
# testuser 的 dbus-run-session 内——直接 fcitx5 --verbose 重启，不嵌套 su。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

currentui() {
    timeout 10 gdbus call --session --dest org.fcitx.Fcitx5 \
        --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.CurrentUI 2>&1
}

echo "== 1) DisabledAddons 生效后的 CurrentUI（主栈 fcitx5，启动时已带禁用）"
currentui || true

echo "== 2) verbose=5 重启（driver 已是 testuser，无需 su）"
pkill -x fcitx5 2>/dev/null || true
sleep 1
fcitx5 --verbose '*' -d --replace >"$LOG_DIR/fcitx5-verbose.log" 2>&1 || true
for _ in $(seq 1 30); do
    currentui >/dev/null 2>&1 && break
    sleep 0.5
done

echo "== 3) 重启后 CurrentUI"
currentui || true

echo "== 4) verbose：UI 候选列表/选择/加载跳过相关行"
grep -aiE "userinterface|uiPriority|uiType|uiName|currentui|uichanged|aiinput-ui|classicui|kimpanel|virtualkeyboard" \
    "$LOG_DIR/fcitx5-verbose.log" | grep -avE "Loading|theme" | head -30

echo "== 5) verbose：告警/跳过类行"
grep -aiE "skip|cannot|fail|invalid|unavailable|not found|disabled" \
    "$LOG_DIR/fcitx5-verbose.log" | grep -avE "portal|wayland connection" | head -20
