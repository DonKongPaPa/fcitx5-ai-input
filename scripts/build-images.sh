#!/usr/bin/env bash
# 构建全部（或指定）镜像。用法：build-images.sh [base|build|niri|kde|gnome|funasr|all]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTX="$ROOT/containers"
TARGETS=("${@:-}")
if [ ${#TARGETS[@]} -eq 0 ] || [ "${TARGETS[0]}" = "all" ]; then
    TARGETS=(base host build niri kde gnome funasr)
fi
# 一次性诊断容器不进 all（按需手动构建）

build() {
    local name="$1" tag="localhost/aiinput-$1"
    if [ ! -f "$CTX/Containerfile.$name" ]; then
        echo ">> 跳过 $name（Containerfile.$name 不存在）"
        return
    fi
    echo ">> 构建镜像 $tag（Containerfile.$name）"
    podman build -t "$tag:latest" -f "$CTX/Containerfile.$name" "$CTX"
}

ensure_image() {
    local name="$1"
    if ! podman image exists "localhost/aiinput-$name:latest"; then
        echo ">> aiinput-$name 不存在，先构建"
        build "$name"
    fi
}

# 依赖顺序：base → host → build/桌面/funasr
for t in "${TARGETS[@]}"; do
    case "$t" in
        base) build base ;;
        host)
            ensure_image base
            build host
            ;;
        build|funasr)
            ensure_image base
            build "$t"
            ;;
        niri|kde|gnome)
            ensure_image base
            ensure_image host
            build "$t"
            ;;
        gtkscale)
            ensure_image niri
            build "$t"
            ;;
        *) echo "未知目标: $t"; exit 1 ;;
    esac
done
echo ">> 完成"
