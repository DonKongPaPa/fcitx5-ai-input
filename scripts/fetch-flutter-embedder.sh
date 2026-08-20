#!/usr/bin/env bash
# 下载 Flutter raw embedder 引擎工件（libflutter_engine.so）到 .cache/flutter-embedder/。
#
# 官方 embedder 工件只有 linux-x64（JIT/debug 引擎）变体——release 目录只有
# GTK 壳（libflutter_linux_gtk.so，不导出 FlutterEngine* C API）。JIT 引擎配
# `flutter build bundle`（kernel_blob）运行，与 v1 实现报告路线一致。
#
# 引擎 hash 必须与本机 Flutter SDK 一致（bin/cache/engine-dart-sdk.stamp），
# 否则 Dart 侧产物与引擎 ABI 不匹配。改 hash 前先跑：
#   cat $(dirname $(readlink -f $(which flutter)))/../bin/cache/engine-dart-sdk.stamp
set -euo pipefail

ENGINE_HASH="0cd610717bde95fd88343c64f81c11ba4e5c0010"
SHA256="e6fbe0368d4d007dc07eeac041ff7be6e3c1ae50144951a5537bed3ac23c6435"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/.cache/flutter-embedder"
URL="https://storage.googleapis.com/flutter_infra_release/flutter/$ENGINE_HASH/linux-x64/linux-x64-embedder.zip"

mkdir -p "$DEST"
if [[ -f "$DEST/libflutter_engine.so" ]]; then
    echo "已存在: $DEST/libflutter_engine.so（删除后重跑可强制更新）"
    exit 0
fi

echo "下载 $URL"
curl -fL "$URL" -o "$DEST/embedder.zip"

# 首次落地的真实校验和（供 CI/他人核对）
actual=$(sha256sum "$DEST/embedder.zip" | cut -d' ' -f1)
if [[ "$actual" != "$SHA256" ]]; then
    echo "sha256 不匹配！" >&2
    echo "  期望: $SHA256" >&2
    echo "  实际: $actual" >&2
    echo "  （上游工件重建会导致校验和变化：核对引擎 hash 后更新本脚本）" >&2
    exit 1
fi

unzip -o -q "$DEST/embedder.zip" -d "$DEST" flutter_embedder.h libflutter_engine.so LICENSE.embedder-archive.md 2>/dev/null \
  || unzip -o -q "$DEST/embedder.zip" -d "$DEST"
rm -f "$DEST/embedder.zip"

# 头文件以仓库 vendor 为准（版本受 git 控制）；.cache 只留 .so
cmp -s "$DEST/flutter_embedder.h" "$ROOT/addon/third_party/flutter_embedder.h" \
  || echo "提示: 下载的 flutter_embedder.h 与 addon/third_party/ 不一致，确认引擎版本后再提交"
rm -f "$DEST/flutter_embedder.h"

echo "完成: $DEST/libflutter_engine.so ($(du -h "$DEST/libflutter_engine.so" | cut -f1))"
