#!/usr/bin/env bash
# Fedora 打包（fedora:latest 容器内运行）：
#   装构建依赖 → stage → rpmbuild（无 spec 源码宏，直接用 stage 布局）→ 安装 → 冒烟
set -euo pipefail
SRC="${SRC:-/work}"
VERSION="${VERSION:-0.1.0}"
export SRC VERSION

dnf -y -q install cmake gcc-c++ make gettext wayland-devel fcitx5-devel fcitx5 \
    pulseaudio-utils dbus-daemon dbus-tools rpm-build findutils >/dev/null 2>&1 \
    || { echo "!! 依赖安装失败"; dnf -q search fcitx5 | head; exit 1; }

bash "$SRC/packaging/common/stage.sh"

# rpm 打包：用 stage 直接铺 BUILDROOT，跳过 spec 的 %build（构建已完成）
RPMDIR=/tmp/rpm
rm -rf "$RPMDIR"
mkdir -p "$RPMDIR"/{BUILDROOT,SPECS,BUILD,SRPMS}
cp "$SRC/packaging/fedora/fcitx5-voice-input.spec" "$RPMDIR/SPECS/"
sed -i "s/^Version:.*/Version:        $VERSION/" "$RPMDIR/SPECS/fcitx5-voice-input.spec"

rpmbuild -bb --define "_topdir $RPMDIR" \
    --define "_stage_src $SRC/packaging/out/stage" \
    --define "debug_package %{nil}" \
    "$RPMDIR/SPECS/fcitx5-voice-input.spec" >/tmp/rpmbuild.log 2>&1 || {
        echo "!! rpmbuild 失败"; grep -aE "^error|not found" /tmp/rpmbuild.log | head; exit 1; }

PKG=$(ls "$RPMDIR"/RPMS/x86_64/*.rpm)
mkdir -p "$SRC/artifacts/packages"
cp "$PKG" "$SRC/artifacts/packages/"
echo ">> 产物: $(basename "$PKG") ($(du -h "$PKG" | cut -f1))"

# 安装 + 冒烟
dnf -y -q install "$PKG" >/dev/null
bash "$SRC/packaging/common/smoke.sh"
