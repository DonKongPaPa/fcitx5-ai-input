#!/usr/bin/env bash
# 构建全部（或指定）镜像。用法：build-images.sh [base|build|niri|kde|gnome|funasr|all]
#
# 基线机制（2026-10-19）：
#   - 每次构建成功同时打日期基线 tag（aiinput-<name>:YYYYMMDD）。cleanup
#     清理 :latest 滚动 tag 时保留基线 tag，重建链可直接复用而免全量重拉
#   - ensure_image 缺失时先试基线 tag（最近日期）→ 镜像缓存 tar
#     （scripts/image-cache.sh save 的产物）→ 都没有才现场构建
#   - 基础 OS 镜像缺失时经国内镜像预拉（docker.io 直连本机 ~40KB/s，
#     daocloud 实测 2 分钟级）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTX="$ROOT/containers"
CACHE_DIR="${AIINPUT_IMAGE_CACHE:-$HOME/.local/share/aiinput-image-cache}"
TODAY="$(date +%Y%m%d)"
TARGETS=("${@:-}")
if [ ${#TARGETS[@]} -eq 0 ] || [ "${TARGETS[0]}" = "all" ]; then
    TARGETS=(base host build niri kde gnome funasr)
fi
# 一次性诊断容器不进 all（按需手动构建）

# 基础 OS 镜像：国内镜像源优先（镜像名 → daocloud 对应路径）
pull_base_os() {
    local ref="$1" mirror="$2"
    podman image exists "$ref" && return 0
    echo ">> 预拉基础镜像 $ref（经 docker.m.daocloud.io）"
    if podman pull -q "$mirror" >/dev/null 2>&1; then
        podman tag "$mirror" "$ref"
        podman rmi "$mirror" >/dev/null 2>&1 || true
        return 0
    fi
    echo ">> daocloud 拉取失败，回退直连 $ref"
    podman pull -q "$ref" >/dev/null
}

build() {
    local name="$1" tag="localhost/aiinput-$1"
    if [ ! -f "$CTX/Containerfile.$name" ]; then
        echo ">> 跳过 $name（Containerfile.$name 不存在）"
        return
    fi
    echo ">> 构建镜像 $tag（Containerfile.$name）"
    podman build -t "$tag:latest" -f "$CTX/Containerfile.$name" "$CTX"
    # 日期基线 tag（同镜像多 tag，零成本）；旧日期基线留作回滚点
    podman tag "$tag:latest" "$tag:$TODAY" 2>/dev/null || true
}

ensure_image() {
    local name="$1" tag="localhost/aiinput-$name"
    podman image exists "$tag:latest" && return 0
    # ① 最近日期基线 tag
    local latest_base
    latest_base=$(podman images --format '{{.Tag}}' "$tag" 2>/dev/null \
        | grep -E '^[0-9]{8}$' | sort | tail -1 || true)
    if [ -n "$latest_base" ]; then
        echo ">> 复用基线 $tag:$latest_base → 打 latest"
        podman tag "$tag:$latest_base" "$tag:latest"
        return 0
    fi
    # ② 镜像缓存 tar
    if [ -f "$CACHE_DIR/aiinput-$name.tar" ]; then
        echo ">> 从缓存加载 $tag（$CACHE_DIR）"
        podman load -i "$CACHE_DIR/aiinput-$name.tar" >/dev/null
        return 0
    fi
    echo ">> $tag 无基线/缓存，现场构建"
    build "$name"
}

# 基础 OS 预拉（只服务镜像构建需要的两个源头；打包容器见
# packaging/*.sh 的 AIINPUT_CN_MIRROR）
case " ${TARGETS[*]} " in
    *" base "*|*" host "*|*" build "*|*" niri "*|*" kde "*|*" gnome "*|*" all "*)
        pull_base_os docker.io/library/archlinux:base-devel \
            docker.m.daocloud.io/library/archlinux:base-devel
        ;;
esac

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
