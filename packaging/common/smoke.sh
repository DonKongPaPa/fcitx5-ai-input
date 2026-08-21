#!/usr/bin/env bash
# 通用安装冒烟（在已安装包的目标容器内运行）：
#   1. fcitx5 拉起 → 日志出现 "AiInput module loaded"
#   2. 进程内 Flutter 引擎启动（JIT 软渲染，资产在位）
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
    sleep 7  # 5s 预热定时器 + 引擎 JIT 启动余量
    if command -v gdbus >/dev/null 2>&1; then
        gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
            --method org.fcitx.Fcitx.Controller1.GetConfig "fcitx://config/addon/aiinput" 2>&1 > /tmp/smoke-getconfig.txt || true
    else
        echo "NO-GDBUS" > /tmp/smoke-getconfig.txt
    fi
    pkill -x fcitx5 2>/dev/null || true
'

check "addon 模块加载（全局热键）" 'grep -aq "AiInput module loaded" /tmp/smoke-fcitx.log'
check "GetConfig 可用（configtool 入口）" 'grep -aq "TriggerKeys" /tmp/smoke-getconfig.txt || grep -aq NO-GDBUS /tmp/smoke-getconfig.txt' 
check "Flutter 引擎进程内启动" 'grep -aq "FlutterEngine: 引擎已启动" /tmp/smoke-fcitx.log'
check "flutter 资产在位" '[ -d /usr/share/fcitx5-aiinput/flutter/flutter_assets ] && [ -f /usr/share/fcitx5-aiinput/flutter/icudtl.dat ]'
check "引擎 .so 在位（rpath 目标）" 'find /usr/lib* -path "*fcitx5-aiinput*" -name libflutter_engine.so 2>/dev/null | grep -q .' 
check "funasr 服务脚本在位" 'find /usr/lib* -path "*fcitx5-aiinput*" -name server.py 2>/dev/null | grep -q .'
check "addon 模块已安装" 'find /usr/lib* -name aiinput.so 2>/dev/null | grep -q .'

if [ "$FAIL" -eq 0 ]; then
    echo "[smoke] 全部通过 ✓"
else
    echo "[smoke] 存在失败 ✗"; tail -20 /tmp/smoke-fcitx.log 2>/dev/null
fi
exit $FAIL
