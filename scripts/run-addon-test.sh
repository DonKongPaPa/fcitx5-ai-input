#!/usr/bin/env bash
# addon-test 容器（快档）：无显示状态机测试——ic-sim 纯 D-Bus 造 IC 驱动
# 按键语义/看门狗/失焦/跨 IC/引擎流。镜像复用 aiinput-base（fcitx5+dbus，
# 无合成器）。触发：改 addon 会话逻辑后；~40s。用法：make addon-test
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="localhost/aiinput-base:latest"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/artifacts/addontest/$RUN_ID"
mkdir -p "$OUT/logs"

[ -x "$ROOT/artifacts/dist/bin/ic-sim" ] || { echo "!! 先 make build（ic-sim 缺失）"; exit 1; }
podman image exists "$IMAGE" || { echo "!! 先 make image-base"; exit 1; }

podman run --rm --user 0 --userns=keep-id \
    -v "$ROOT/scripts:/scripts:ro" \
    -v "$ROOT/artifacts/dist:/opt/dist:ro" \
    -v "$OUT:/out" \
    -e LOG_DIR=/out/logs -e OUT_DIR=/out \
    "$IMAGE" \
    bash -c '
        set -e
        cp -r /opt/dist/* /usr/
        chown -R testuser:testuser /out 2>/dev/null || true
        su testuser -c "dbus-run-session -- bash /scripts/env/start-headless.sh"
    '
status=$?
python3 - "$OUT/case-results.jsonl" <<'EOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
fails = [r for r in rows if r["status"] != "pass"]
for r in rows:
    print(f"{r['status'].upper()} {r['id']} | {r['actual'][:90]}")
print(f"== addon-test: {len(rows)} 例, {len(fails)} 失败")
sys.exit(1 if fails else 0)
EOF
echo ">> 报告：$OUT/case-results.jsonl"
exit $status
