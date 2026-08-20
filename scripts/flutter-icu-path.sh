#!/usr/bin/env bash
# 定位当前 Flutter SDK 的 icudtl.dat（与引擎 .so 同 SDK，保证 ICU 版本匹配）
set -euo pipefail
FLUTTER_BIN=$(readlink -f "$(command -v flutter)")
SDK=$(dirname "$(dirname "$FLUTTER_BIN")")
ICU="$SDK/bin/cache/artifacts/engine/linux-x64/icudtl.dat"
if [[ ! -f "$ICU" ]]; then
    echo "未找到 $ICU（先 flutter precache --linux）" >&2
    exit 1
fi
echo "$ICU"
