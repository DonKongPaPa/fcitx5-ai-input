#!/usr/bin/env bash
# 下载 Flutter raw embedder 引擎工件（libflutter_engine.so）到 .cache/flutter-embedder/。
#
# 官方 embedder 工件只有 linux-x64（JIT/debug 引擎）变体——release 目录只有
# GTK 壳（libflutter_linux_gtk.so，不导出 FlutterEngine* C API）。JIT 引擎配
# `flutter build bundle`（kernel_blob）运行，与 v1 实现报告路线一致。
#
# 引擎 hash 的唯一真源 = aiinput-build 镜像里的 Flutter SDK
# （/opt/flutter/bin/cache/engine-dart-sdk.stamp）。kernel_blob、icudtl.dat、
# goldens 全部出自同一镜像 SDK——本脚本下载的 .so 必须与镜像 stamp 一致，
# 否则 Dart 产物与引擎 ABI 不匹配。镜像升 SDK（改 Containerfile.build 的
# FLUTTER_VERSION）后必须同步更新下方 ENGINE_HASH 并重下。
set -euo pipefail

ENGINE_HASH="5f77625673248ee5846fbcaf5d3e1a3878386fd7"  # aiinput-build SDK 3.47.0
SHA256="5c02c78145c51682138a5c75db1348f9f2ca90236373f0c106df77d0f36380c6"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/.cache/flutter-embedder"
URL="https://storage.googleapis.com/flutter_infra_release/flutter/$ENGINE_HASH/linux-x64/linux-x64-embedder.zip"
BUILD_IMAGE="${BUILD_IMAGE:-localhost/aiinput-build:latest}"

# 防漂移：镜像存在时校验其 SDK stamp 与本脚本 hash 一致（镜像先升 SDK
# 而忘了改这里 = 当场红，而不是运行时 ABI 错配）
if podman image exists "$BUILD_IMAGE" 2>/dev/null; then
    STAMP="$(podman run --rm "$BUILD_IMAGE" \
        cat /opt/flutter/bin/cache/engine-dart-sdk.stamp 2>/dev/null || true)"
    if [ -n "$STAMP" ] && [ "$STAMP" != "$ENGINE_HASH" ]; then
        echo "!! 镜像 SDK stamp（$STAMP）≠ 脚本 ENGINE_HASH（$ENGINE_HASH）" >&2
        echo "   镜像升过 SDK：更新本脚本 ENGINE_HASH/SHA256 后重跑" >&2
        exit 1
    fi
fi

mkdir -p "$DEST"
if [[ -f "$DEST/libflutter_engine.so" ]]; then
    echo "已存在: $DEST/libflutter_engine.so（删除后重跑可强制更新）"
    exit 0
fi

echo "下载 $URL"
curl -fL "$URL" -o "$DEST/embedder.zip"

# 落地校验（上游工件重建会导致校验和变化：核对引擎 hash 后更新本脚本）
actual=$(sha256sum "$DEST/embedder.zip" | cut -d' ' -f1)
if [[ "$actual" != "$SHA256" ]]; then
    echo "sha256 不匹配！" >&2
    echo "  期望: $SHA256" >&2
    echo "  实际: $actual" >&2
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
