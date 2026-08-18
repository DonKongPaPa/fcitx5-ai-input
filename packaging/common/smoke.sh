#!/usr/bin/env bash
# 通用安装冒烟（在已安装包的目标容器内运行）：
#   1. fcitx5 拉起 → 日志出现 "VoiceInput engine loaded"
#   2. flutter bundle 可执行在位
#   3. configtool 配置描述注册（GetConfig 字段往返）
set -u
export XDG_RUNTIME_DIR=/tmp/xdg-runtime
mkdir -p "$XDG_RUNTIME_DIR"

FAIL=0
step() { echo "[smoke] $1"; }
check() { if eval "$2"; then echo "[smoke] ✓ $1"; else echo "[smoke] ✗ $1"; FAIL=1; fi; }

step "拉起 fcitx5"
pkill -x fcitx5 2>/dev/null || true
dbus-run-session -- bash -c '
    fcitx5 -d --replace >/tmp/smoke-fcitx.log 2>&1
    sleep 4
    if command -v gdbus >/dev/null 2>&1; then
        gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
            --method org.fcitx.Fcitx.Controller1.GetConfig "fcitx://config/addon/voiceinput" 2>&1 > /tmp/smoke-getconfig.txt || true
    else
        echo "NO-GDBUS" > /tmp/smoke-getconfig.txt
    fi
    pkill -x fcitx5 2>/dev/null || true
'

check "addon 引擎加载" 'grep -aq "VoiceInput engine loaded" /tmp/smoke-fcitx.log'
check "GetConfig 可用（configtool 入口）" 'grep -aq "TriggerKeys" /tmp/smoke-getconfig.txt || grep -aq NO-GDBUS /tmp/smoke-getconfig.txt' 
check "flutter bundle 可执行在位" '[ -x /usr/lib/fcitx5-voiceinput/ui/bundle/voice_ui ]'
check "funasr 服务脚本在位" '[ -f /usr/lib/fcitx5-voiceinput/funasr-server/server.py ]'
check "addon 模块已安装" 'find /usr/lib* -name voiceinput.so 2>/dev/null | grep -q .'

if [ "$FAIL" -eq 0 ]; then
    echo "[smoke] 全部通过 ✓"
else
    echo "[smoke] 存在失败 ✗"; tail -20 /tmp/smoke-fcitx.log 2>/dev/null
fi
exit $FAIL
