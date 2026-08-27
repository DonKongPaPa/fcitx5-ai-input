#!/usr/bin/env bash
# ui-test 容器（快档）：flutter test + golden 基线 + 回放断言，无桌面栈。
# 镜像复用 aiinput-build（Flutter SDK 3.47.0 sha256 pin——golden 可重现
# 的前提）。触发：改 flutter/lib 后随手；pre-PR。
# 用法：make ui-test  或  UPDATE_GOLDENS=1 ./scripts/run-ui-test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="localhost/aiinput-build:latest"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/artifacts/uitest/$RUN_ID"
mkdir -p "$OUT"

[ -d "$ROOT/flutter/lib" ] || { echo "!! flutter/ 源码缺失"; exit 1; }
podman image exists "$IMAGE" || { echo "!! 先 make image-build"; exit 1; }

UPDATE="${UPDATE_GOLDENS:-0}"
podman run --rm --userns=keep-id \
    -v "$ROOT/flutter:/work" \
    -v "$ROOT/lab:/lab:ro" \
    -v "$OUT:/out" \
    -w /work \
    -e UPDATE_GOLDENS="$UPDATE" \
    "$IMAGE" \
    bash -c '
        set -e
        flutter pub get >/dev/null 2>&1 || flutter pub get
        if [ "$UPDATE_GOLDENS" = "1" ]; then
            flutter test --update-goldens 2>&1 | tee /out/ui-test.log | tail -20
        else
            flutter test 2>&1 | tee /out/ui-test.log | tail -20
        fi
    '
echo ">> ui-test 完成：$OUT/ui-test.log（golden 基线 flutter/test/goldens/）"
