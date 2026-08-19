#!/usr/bin/env bash
# 语音输入部署健康检查（一键排查）
# 用法：healthcheck.sh [deep]   # deep 含 sherpa 模型试加载（~1s）
set -euo pipefail
MODE="${1:-}"
out=$(gdbus call --session --dest org.fcitx.Fcitx5 \
    --object-path /org/fcitx/VoiceInput \
    --method org.fcitx.VoiceInput.Test.HealthCheck "$MODE" 2>&1)
# gdbus 返回 ('<json>')——剥壳后美化
json=$(echo "$out" | sed "s/^('//; s/',)$//; s/\\\\\"/\"/g")
if command -v python3 >/dev/null; then
    echo "$json" | python3 -m json.tool 2>/dev/null || echo "$json"
else
    echo "$json"
fi
