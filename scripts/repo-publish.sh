#!/usr/bin/env bash
# 组装 pacman 仓库发布树：Pages 内容（db/签名钥/安装器）+ 包与 .sig 集合。
# 须在有 repo-add/gpg 的环境跑（CI: archlinux:base-devel 容器；本地: 同款 podman）。
# 用法: repo-publish.sh <pages输出目录> <pkg.tar.zst>...
# 签名私钥二选一注入：PACMAN_REPO_SIGNING_KEY（armored，CI secret）
#                  或 PACMAN_REPO_SIGNING_KEY_FILE（本地测试）
# 本地隔离示例：GNUPGHOME=$(mktemp -d) PACMAN_REPO_SIGNING_KEY_FILE=... bash scripts/repo-publish.sh
set -euo pipefail

OUT=${1:?用法: repo-publish.sh <pages输出目录> <pkg.tar.zst>...}
shift
[ "$#" -ge 1 ] || { echo "至少一个 .pkg.tar.zst" >&2; exit 1; }
for cmd in repo-add gpg; do
    command -v "$cmd" >/dev/null || { echo "缺 $cmd（须在 arch 环境跑）" >&2; exit 1; }
done

REPO=fcitx5-ai-input
ROOT=$(cd "$(dirname "$0")/.." && pwd)

if [ -n "${PACMAN_REPO_SIGNING_KEY:-}" ]; then
    printf '%s' "$PACMAN_REPO_SIGNING_KEY" | gpg --batch --import
elif [ -n "${PACMAN_REPO_SIGNING_KEY_FILE:-}" ]; then
    gpg --batch --import "$PACMAN_REPO_SIGNING_KEY_FILE"
fi
FPR=$(gpg --list-secret-keys --with-colons 'fcitx5-ai-input pacman repo' \
    | awk -F: '/^fpr/{print $10; exit}')
[ -n "$FPR" ] || { echo "没找到 fcitx5-ai-input 签名私钥" >&2; exit 1; }

mkdir -p "$OUT/x86_64"
for pkg in "$@"; do
    [ -f "$pkg" ] || { echo "不存在: $pkg" >&2; exit 1; }
    cp -f "$pkg" "$OUT/x86_64/"
    name=$(basename "$pkg")
    gpg --batch --yes --pinentry-mode loopback --passphrase '' --local-user "$FPR" \
        --detach-sign --output "$OUT/x86_64/$name.sig" "$OUT/x86_64/$name"
done

# db 文件名即仓库名；--sign 给 db 出签名。pacman 实际请求 <repo>.db /
# <repo>.db.sig，而 repo-add 产出 .db.tar.gz(+.sig)，故补齐两者。
GPGKEY="$FPR" repo-add --sign "$OUT/x86_64/$REPO.db.tar.gz" "$OUT/x86_64/"*.pkg.tar.zst
# 新版 repo-add 已自动建 <repo>.db(.sig) 符号链接；旧版缺失时兜底补齐
[ -e "$OUT/x86_64/$REPO.db.sig" ] || \
    cp -f "$OUT/x86_64/$REPO.db.tar.gz.sig" "$OUT/x86_64/$REPO.db.sig"

cp -f "$ROOT/scripts/pacman-repo-install.sh" "$OUT/install.sh"
cp -f "$ROOT/packaging/arch/repo-key.asc" "$OUT/repo-key.asc"
cp -f "$ROOT/packaging/arch/pages-README.md" "$OUT/README.md"

echo "—— $OUT 发布树 ——"
find "$OUT" \( -type f -o -type l \) | sort
