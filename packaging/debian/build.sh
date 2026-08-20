#!/usr/bin/env bash
# Debian 打包（debian:bookworm 容器内运行）：
#   装构建依赖 → stage → dpkg-deb 手工布局 → 安装 → 冒烟
set -euo pipefail
SRC="${SRC:-/work}"
VERSION="${VERSION:-0.1.0}"
export SRC VERSION

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends \
    build-essential cmake pkg-config gettext dbus \
    libfcitx5core-dev libfcitx5utils-dev libfcitx5config-dev \
    fcitx5-modules-dev fcitx5 libwayland-dev libwayland-bin \
    libfontconfig1-dev pulseaudio-utils libglib2.0-bin \
    >/dev/null 2>&1 || { echo "!! 依赖安装失败"; apt-cache search fcitx5 | head -10; exit 1; }

bash "$SRC/packaging/common/stage.sh"

STAGE="$SRC/packaging/out/stage"
PKGDIR=/tmp/debpkg
rm -rf "$PKGDIR"
mkdir -p "$PKGDIR/DEBIAN"
cp -a "$STAGE/usr" "$PKGDIR/"

cat > "$PKGDIR/DEBIAN/control" <<EOF
Package: fcitx5-voice-input
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Depends: fcitx5, pulseaudio-utils, libfontconfig1
Maintainer: DonKongPaPa <raykent92@gmail.com>
Description: Fcitx5 voice input: ASR + LLM-polished candidates
 Voice input for fcitx5: FunASR streaming (31 languages) or local
 GGUF engine, Flutter Material 3 overlay near the cursor, LLM-polished
 candidate selection (keyboard/mouse), hot-reload settings via
 fcitx5-configtool.
EOF
# fcitx5 addon 配置注册（首次安装刷新缓存）
cat > "$PKGDIR/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v fcitx5 >/dev/null 2>&1; then
    fcitx5 --version >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 755 "$PKGDIR/DEBIAN/postinst"

PKG="$SRC/artifacts/packages/fcitx5-voice-input_${VERSION}-1_amd64.deb"
mkdir -p "$SRC/artifacts/packages"
dpkg-deb --root-owner-group -Zxz --build "$PKGDIR" "$PKG" >/dev/null
echo ">> 产物: $PKG ($(du -h "$PKG" | cut -f1))"

# 安装 + 冒烟
apt-get install -y -qq "$PKG" >/dev/null 2>&1 || dpkg -i --force-depends "$PKG" >/dev/null
bash "$SRC/packaging/common/smoke.sh"
