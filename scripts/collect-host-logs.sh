#!/usr/bin/env bash
# 宿主侧诊断证据收集（报漏字/截断/定位问题时跑这个打包证据）。
# 用法：collect-host-logs.sh [since]   # since 默认 today；如 "-2 hours"
# 产物：artifacts/hostlogs/<时间戳>/
#   journal.log    fcitx5 的 AiInput/Sherpa/FlutterEngine 相关日志
#   sessions.jsonl 会话证据（双路 final + partial 序列；addon 0.4.3+）
#   wav/           会话音频留档（SessionDumpAudio 开启时；含语音内容）
#   versions.txt   包版本 / fcitx5 版本 / 相关配置
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SINCE="${1:-today}"
OUT="$ROOT/artifacts/hostlogs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT/wav"

journalctl -t fcitx5 --since "$SINCE" --no-pager 2>/dev/null \
    | grep -aE "AiInput|Sherpa|FlutterEngine|VoicePopup|segfault|error" \
    > "$OUT/journal.log" || true

SESS="$HOME/.local/state/fcitx5-aiinput/sessions"
if [ -f "$SESS/sessions.jsonl" ]; then
    cp "$SESS/sessions.jsonl" "$OUT/sessions.jsonl"
fi
# 只拷 journal 时间窗内引用的 wav（jsonl 的 ts_ms 字段对账；全拷会很大）
if [ -f "$OUT/sessions.jsonl" ]; then
    python3 - "$SESS" "$OUT/wav" "$SINCE" << 'EOF'
import json, sys, os, shutil, datetime
sess_dir, out_dir, since = sys.argv[1], sys.argv[2], sys.argv[3]
# 宽松解析 since（today / -N hours / YYYY-MM-DD）→ 时间下界
now = datetime.datetime.now()
if since == "today":
    lo = now.replace(hour=0, minute=0, second=0, microsecond=0)
elif since.startswith("-"):
    hours = float(since.split()[0][1:] or 0)
    lo = now - datetime.timedelta(hours=hours)
else:
    lo = datetime.datetime.fromisoformat(since)
lo_ms = int(lo.timestamp() * 1000)
n = 0
for line in open(os.path.join(sess_dir, "sessions.jsonl")):
    try:
        rec = json.loads(line)
    except Exception:
        continue
    audio = rec.get("audio", "")
    if audio and rec.get("ts_ms", 0) >= lo_ms:
        src = os.path.join(sess_dir, audio)
        if os.path.exists(src):
            shutil.copy2(src, out_dir)
            n += 1
print(f"wav 拷贝 {n} 个（≥ {lo.isoformat()}）")
EOF
fi

{
    echo "package: $(pacman -Q fcitx5-ai-input 2>/dev/null || echo unknown)"
    echo "fcitx5: $(fcitx5 --version 2>/dev/null | head -1)"
    echo "since: $SINCE"
    echo "---- aiinput.conf ----"
    cat ~/.config/fcitx5/conf/aiinput.config 2>/dev/null || true
} > "$OUT/versions.txt"

echo ">> 证据已收集：$OUT（$(du -sh "$OUT" | cut -f1)）"
