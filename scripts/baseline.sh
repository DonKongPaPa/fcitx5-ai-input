#!/usr/bin/env bash
# 将指定环境最近一次全部通过运行的录屏存为本地基准（bug 对照用）
# 用法：baseline.sh niri|kde|gnome [run_id]
# 不带 run_id 时取该环境最新的报告；基准仅保留在本地（artifacts/reference/，不进 git）
set -euo pipefail

ENV_NAME="${1:?用法: baseline.sh niri|kde|gnome [run_id]}"
RUN_ID="${2:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORTS="$ROOT/artifacts/reports"
REF="$ROOT/artifacts/reference/$ENV_NAME"

if [ -z "$RUN_ID" ]; then
    RUN_ID="$(ls -1 "$REPORTS" 2>/dev/null | grep -- "-${ENV_NAME}$" | sort | tail -1 || true)"
fi
[ -n "$RUN_ID" ] || { echo "找不到 $ENV_NAME 的报告"; exit 1; }

REPORT="$REPORTS/$RUN_ID/report.json"
[ -f "$REPORT" ] || { echo "报告不存在：$REPORT"; exit 1; }

fails="$(python3 -c "import json,sys; print(json.load(open('$REPORT'))['summary']['failed'])")"
[ "$fails" = "0" ] || { echo "该运行有 $fails 个失败用例，不能作为基准"; exit 1; }

mkdir -p "$REF"
count=0
while IFS= read -r rec; do
    case_id="$(basename "$rec" .mp4)"
    cp -f "$ROOT/artifacts/$rec" "$REF/$case_id.mp4"
    count=$((count + 1))
done < <(python3 -c "import json; [print(c['recording']) for c in json.load(open('$REPORT'))['cases'] if c.get('recording')]")

echo ">> 基准已更新：$REF（$count 个录屏，来自 $RUN_ID）"
