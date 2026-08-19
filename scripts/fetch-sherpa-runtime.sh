#!/usr/bin/env bash
# 下载 sherpa-onnx 运行时（libsherpa-onnx-c-api.so + libonnxruntime.so）到
# .cache/sherpa-onnx/。版本钉死 v1.13.6（与实验 004 的 pip 版一致）+
# sha256 强校验。
#
# 变体选择 shared-no-tts-lib（无 TTS，最小）：3.5M + 26M
set -euo pipefail

VERSION="1.13.6"
SHA256="dfeef9da664faab279582ee10c4191ea8ff5a8251141c719f9da5598768be95b"
BASE_URL="${SHERPA_MIRROR:-https://github.com}/k2-fsa/sherpa-onnx/releases/download"
URL="$BASE_URL/v$VERSION/sherpa-onnx-v$VERSION-linux-x64-shared-no-tts-lib.tar.bz2"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/.cache/sherpa-onnx"
mkdir -p "$DEST"

if [[ -f "$DEST/libsherpa-onnx-c-api.so" && -f "$DEST/libonnxruntime.so" ]]; then
    echo "已存在: $DEST（删除后重跑可强制更新）"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "下载 $URL"
curl -fL "$URL" -o "$TMP/rt.tar.bz2"

actual=$(sha256sum "$TMP/rt.tar.bz2" | cut -d' ' -f1)
if [[ "$actual" != "$SHA256" ]]; then
    echo "sha256 不匹配！期望 $SHA256 实际 $actual" >&2
    echo "（上游重发布会导致校验和变化：核对版本后更新本脚本）" >&2
    exit 1
fi

tar xf "$TMP/rt.tar.bz2" -C "$TMP"
cp "$TMP"/sherpa-onnx-v$VERSION-linux-x64-shared-no-tts-lib/lib/libsherpa-onnx-c-api.so "$DEST/"
cp "$TMP"/sherpa-onnx-v$VERSION-linux-x64-shared-no-tts-lib/lib/libonnxruntime.so "$DEST/"

echo "完成: $DEST（$(du -sh "$DEST" | cut -f1)）"
