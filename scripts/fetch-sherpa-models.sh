#!/usr/bin/env bash
# 下载 sherpa-onnx 双语流式模型（zh/en paraformer int8）到用户模型目录。
#
# 用法：
#   fetch-sherpa-models.sh [--dest DIR] [--from-local DIR]
#   --dest       目标目录（默认 ~/.local/share/fcitx5-voiceinput/models/sherpa-paraformer）
#   --from-local 从本地已有目录复制（如实验 004 的下载副本），跳过网络下载
#   SHERPA_MIRROR=https://ghproxy... 环境变量可加 GitHub 镜像前缀
#
# 模型：sherpa-onnx-streaming-paraformer-bilingual-zh-en（asr-models release，
# 实测 RSS 412MB / 首字 0.069s / RTF 0.04）。只落 int8 三件
#（encoder.int8.onnx 158M + decoder.int8.onnx 68M + tokens.txt），
# fp32 变体不装。
#
# 注意：asr-models 是滚动 release（无版本号），以 tar 的 sha256 强校验锁定；
# 上游重传会导致校验失败——此时需人工核对模型后更新本脚本的 SHA256。
set -euo pipefail

SHA256="5462a1fce42693deae572af1e8c4687124b12aa85fe61ff4d3168bb5280e205f"
BASE_URL="${SHERPA_MIRROR:-https://github.com}/k2-fsa/sherpa-onnx/releases/download"
URL="$BASE_URL/asr-models/sherpa-onnx-streaming-paraformer-bilingual-zh-en.tar.bz2"

DEST="$HOME/.local/share/fcitx5-voiceinput/models/sherpa-paraformer"
FROM_LOCAL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest) DEST="$2"; shift 2 ;;
        --from-local) FROM_LOCAL="$2"; shift 2 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

if [[ -f "$DEST/tokens.txt" && -f "$DEST/encoder.int8.onnx" &&
      -f "$DEST/decoder.int8.onnx" ]]; then
    echo "模型已齐: $DEST"
    exit 0
fi

install_files() {  # $1 = 源目录
    mkdir -p "$DEST"
    for f in tokens.txt encoder.int8.onnx decoder.int8.onnx; do
        [[ -f "$1/$f" ]] || { echo "!! 源目录缺 $f: $1" >&2; exit 1; }
    done
    cp "$1/tokens.txt" "$1/encoder.int8.onnx" "$1/decoder.int8.onnx" "$DEST/"
}

if [[ -n "$FROM_LOCAL" ]]; then
    install_files "$FROM_LOCAL"
    echo "完成（本地复制）: $DEST"
    exit 0
fi

if false; then  # sha256 已固化
    echo "!! 本脚本尚未填入模型 sha256（首次落地时回填）" >&2
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "下载 $URL（约 1GB，含未用的 fp32 变体）"
curl -fL "$URL" -o "$TMP/model.tar.bz2"

actual=$(sha256sum "$TMP/model.tar.bz2" | cut -d' ' -f1)
if [[ "$actual" != "$SHA256" ]]; then
    echo "sha256 不匹配！期望 $SHA256 实际 $actual" >&2
    echo "（asr-models 为滚动 release：核对模型后更新本脚本 SHA256）" >&2
    exit 1
fi

tar xf "$TMP/model.tar.bz2" -C "$TMP"
install_files "$TMP"/sherpa-onnx-streaming-paraformer-bilingual-zh-en
echo "完成: $DEST（$(du -sh "$DEST" | cut -f1)）"
