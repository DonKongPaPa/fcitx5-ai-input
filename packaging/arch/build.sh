#!/usr/bin/env bash
# Arch 打包（archlinux:base-devel 容器内运行）：
#   装依赖 → stage → 手工组 .pkg.tar.zst（.PKGINFO，pacman -U 兼容，
#   免 makepkg 的 root/fakeroot 纠缠）→ 安装 → 冒烟
# 注意：脚本内禁止对 /work 做任何 chown（rootless 容器的 chown 会把
# 宿主文件改成 subuid 属主，夺走宿主写权限——踩过）
set -euo pipefail
SRC="${SRC:-/work}"
VERSION="${VERSION:-0.1.0}"
export SRC VERSION

pacman -Syu --noconfirm --needed cmake gcc wayland fontconfig fcitx5 libpulse dbus zstd \
    >/dev/null 2>&1 || { echo "!! 依赖安装失败"; exit 1; }
pacman -Scc --noconfirm >/dev/null 2>&1 || true

bash "$SRC/packaging/common/stage.sh"

STAGE="$SRC/packaging/out/stage"
PKG="$SRC/artifacts/packages/fcitx5-ai-input-$VERSION-1-x86_64.pkg.tar.zst"
mkdir -p "$SRC/artifacts/packages"

cd "$STAGE"
{
    echo "pkgname = fcitx5-ai-input"
    echo "pkgver = $VERSION-1"
    echo "pkgdesc = Fcitx5 voice input: sherpa-onnx streaming ASR (FunASR/GGUF tiers) + Flutter MD3 cursor-following card"
    echo "url = https://github.com/DonKongPaPa/fcitx5-ai-input"
    echo "builddate = $(date +%s)"
    echo "packager = CI <ci@invalid>"
    echo "size = $(du -sb "$STAGE" | cut -f1)"
    echo "arch = x86_64"
    echo "license = MIT"
    echo "depend = fcitx5"
    echo "depend = libpulse"
} > .PKGINFO
tar --zstd -cf "$PKG" .PKGINFO usr
rm .PKGINFO
echo ">> 产物: $PKG ($(du -h "$PKG" | cut -f1))"

# 安装 + 冒烟
pacman -U --noconfirm "$PKG" >/dev/null
bash "$SRC/packaging/common/smoke.sh"
