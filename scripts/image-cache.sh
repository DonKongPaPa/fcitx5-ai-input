#!/usr/bin/env bash
# 基线镜像缓存：podman save/load 到本地 tar，全量重建（换机/cleanup --all/
# 存储损坏）时免重拉基础 OS + 免跑全链 pacman。用法：
#   image-cache.sh save  [base host build niri kde gnome funasr]  # 缺省=全部存在的
#   image-cache.sh load  [名字...]                                # 缺省=缓存里全部
#   image-cache.sh list
# 位置：$AIINPUT_IMAGE_CACHE（默认 ~/.local/share/aiinput-image-cache），
#   与 cleanup.sh 的镜像清理无联动（缓存独立保留，手动删）。
set -euo pipefail

CACHE_DIR="${AIINPUT_IMAGE_CACHE:-$HOME/.local/share/aiinput-image-cache}"
ALL="base host build niri kde gnome funasr"
mkdir -p "$CACHE_DIR"

cmd="${1:-}"
shift || true
case "$cmd" in
    save)
        names=("$@")
        [ ${#names[@]} -eq 0 ] && names=($ALL)
        for n in "${names[@]}"; do
            ref="localhost/aiinput-$n:latest"
            if podman image exists "$ref"; then
                echo ">> save $ref → $CACHE_DIR/aiinput-$n.tar"
                podman save -o "$CACHE_DIR/aiinput-$n.tar" "$ref"
            else
                echo ">> 跳过 $n（镜像不存在）"
            fi
        done
        du -sh "$CACHE_DIR" 2>/dev/null | sed 's/^/   缓存总占用 /'
        ;;
    load)
        names=("$@")
        if [ ${#names[@]} -eq 0 ]; then
            for f in "$CACHE_DIR"/aiinput-*.tar; do
                [ -e "$f" ] || continue
                names+=("$(basename "$f" .tar | sed 's/^aiinput-//')")
            done
        fi
        [ ${#names[@]} -gt 0 ] || { echo "缓存为空（$CACHE_DIR）"; exit 0; }
        for n in "${names[@]}"; do
            f="$CACHE_DIR/aiinput-$n.tar"
            [ -f "$f" ] || { echo ">> 无缓存 $n（$f）"; continue; }
            echo ">> load $f"
            podman load -i "$f" >/dev/null
        done
        ;;
    list)
        echo "== 本地镜像"
        podman images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' \
            | grep '^localhost/aiinput-' | sort || true
        echo "== 缓存 tar"
        ls -lh "$CACHE_DIR"/aiinput-*.tar 2>/dev/null || echo "   （空）"
        ;;
    *)
        echo "用法: image-cache.sh save|load|list [名字...]"
        exit 1
        ;;
esac
