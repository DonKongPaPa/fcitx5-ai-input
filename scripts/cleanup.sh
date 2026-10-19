#!/usr/bin/env bash
# 本地测试残留清理（镜像/容器/报告/打包产物）。用法：
#   cleanup.sh                # 安全档：残留概览 + 报告/打包产物按保留数裁剪
#   cleanup.sh --containers   # + 清掉 aiinput 相关退出容器与孤儿 run 进程
#   cleanup.sh --images       # + 删除全部 localhost/aiinput-* 镜像（下次
#                             #   make test 会自动重建链，耗时数分钟）
#   cleanup.sh --all          # 上述全部 + 报告全清
#   KEEP_REPORTS=N KEEP_PACKAGES=N 自定义保留数（默认 10 / 4）
# 只碰本项目（aiinput）对象；其他项目的容器/镜像/数据不动。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ART="$ROOT/artifacts"
KEEP_REPORTS="${KEEP_REPORTS:-10}"
KEEP_PACKAGES="${KEEP_PACKAGES:-4}"

MODE_CONTAINERS=0 MODE_IMAGES=0 ALL=0
for a in "$@"; do
    case "$a" in
        --containers) MODE_CONTAINERS=1 ;;
        --images) MODE_IMAGES=1 ;;
        --all) ALL=1 ;;
        *) echo "未知参数: $a"; exit 1 ;;
    esac
done

prune_dirs() { # $1=目录 $2=保留数 $3=说明
    local d="$1" keep="$2"
    [ -d "$d" ] || return 0
    local total
    total=$(ls -1 "$d" 2>/dev/null | wc -l)
    [ "$total" -gt "$keep" ] || return 0
    echo ">> $3：$total 项，保留最新 $keep"
    ls -1 "$d" | sort | head -n "-$keep" | while read -r p; do
        rm -rf "$d/$p"
    done
}

echo "== 残留概览"
if command -v podman >/dev/null 2>&1; then
    imgs=$(podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | grep -c '^localhost/aiinput-' || true)
    ctms=$(podman ps -a --format '{{.Image}}' 2>/dev/null \
        | grep -c '^localhost/aiinput-' || true)
    echo "   aiinput 镜像 $imgs 个 / 容器 $ctms 个"
fi
[ -d "$ART" ] && du -sh "$ART" 2>/dev/null | sed 's/^/   artifacts /'

# —— podman（仅 --containers/--images/--all 时）——
if command -v podman >/dev/null 2>&1; then
    if [ "$MODE_CONTAINERS" = 1 ] || [ "$ALL" = 1 ]; then
        # 孤儿 run（被杀会话留下的容器进程会阻塞后续 podman 操作）
        pkill -9 -f "podman run.*aiinput" 2>/dev/null \
            && echo ">> 已杀掉孤儿 podman run 进程" || true
        ids=$(podman ps -a --format '{{.ID}} {{.Image}}' 2>/dev/null \
            | awk '$2 ~ /^localhost\/aiinput-/ {print $1}')
        [ -n "$ids" ] && { echo ">> 清理容器: $(echo "$ids" | wc -l) 个"; podman rm -f $ids >/dev/null; } \
            || echo ">> 无 aiinput 容器"
    fi
    if [ "$MODE_IMAGES" = 1 ] || [ "$ALL" = 1 ]; then
        imgs=$(podman images --format '{{.ID}} {{.Repository}}:{{.Tag}}' 2>/dev/null \
            | awk '$2 ~ /^localhost\/aiinput-/ {print $1}' | sort -u)
        [ -n "$imgs" ] && { echo ">> 删除镜像: $(echo "$imgs" | wc -l) 个"; podman rmi -f $imgs >/dev/null; } \
            || echo ">> 无 aiinput 镜像"
    fi
fi

# —— 报告与打包产物（默认就跑；--all 时报告全清）——
if [ "$ALL" = 1 ]; then
    [ -d "$ART/reports" ] && { echo ">> 全清报告"; rm -rf "$ART/reports"; }
else
    prune_dirs "$ART/reports" "$KEEP_REPORTS" "历史报告 reports"
fi
prune_dirs "$ART/packages" "$KEEP_PACKAGES" "本地打包产物 packages"
echo ">> 完成"
