#!/usr/bin/env bash
# 构建全部（或指定）镜像。用法：build-images.sh [base|build|niri|kde|gnome|funasr|all]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTX="$ROOT/containers"
TARGETS=("${@:-}")
if [ ${#TARGETS[@]} -eq 0 ] || [ "${TARGETS[0]}" = "all" ]; then
    TARGETS=(base build niri kde gnome funasr)
fi

build() {
    local name="$1" tag="localhost/voiceinput-$1"
    if [ ! -f "$CTX/Containerfile.$name" ]; then
        echo ">> 跳过 $name（Containerfile.$name 不存在）"
        return
    fi
    echo ">> 构建镜像 $tag（Containerfile.$name）"
    podman build -t "$tag:latest" -f "$CTX/Containerfile.$name" "$CTX"
}

# 依赖顺序：base → build/桌面/funasr
for t in "${TARGETS[@]}"; do
    case "$t" in
        base) build base ;;
        build|niri|kde|gnome|funasr)
            # 依赖 base 先存在
            if ! podman image exists localhost/voiceinput-base:latest; then
                echo ">> voiceinput-base 不存在，先构建 base"
                build base
            fi
            build "$t"
            ;;
        *) echo "未知目标: $t"; exit 1 ;;
    esac
done
echo ">> 完成"
