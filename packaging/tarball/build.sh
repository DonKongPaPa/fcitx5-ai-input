#!/usr/bin/env bash
# Tarball 打包（任意基座容器内运行）：
#   源码 + install.sh + 预编译 flutter bundle → tar.gz；
#   冒烟：在 ubuntu 容器内执行 install.sh 后验证（与发行版包同套冒烟）
set -euo pipefail
SRC="${SRC:-/work}"
VERSION="${VERSION:-0.1.0}"
export SRC VERSION

# 冒烟需要构建依赖 + git（tarball 源码含 .git 时走 git archive）
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq --no-install-recommends         build-essential cmake pkg-config gettext git dbus         libfcitx5core-dev libfcitx5utils-dev libfcitx5config-dev         fcitx5-modules-dev fcitx5 libwayland-dev libwayland-bin         pulseaudio-utils libglib2.0-bin >/dev/null 2>&1 || true
fi

NAME="fcitx5-voice-input-$VERSION"
STAGE=/tmp/tarball/$NAME
rm -rf /tmp/tarball; mkdir -p "$STAGE"

# 源码（git 优先，回退当前目录拷贝）
if git -C "$SRC" rev-parse >/dev/null 2>&1; then
    git -C "$SRC" archive HEAD --prefix="$NAME/" | tar -x -C /tmp/tarball
else
    cp -a "$SRC/." "$STAGE/"
fi

# 清理源码内不需要进 tarball 的内容
rm -rf "$STAGE/artifacts" "$STAGE/.git" "$STAGE/build" \
       "$STAGE/experiments" "$STAGE/语音测试集" "$STAGE/.zcode" "$STAGE/.funasr-env"

# 预编译 flutter bundle
BUNDLE="${FLUTTER_BUNDLE:-$SRC/artifacts/dist/lib/fcitx5-voiceinput/ui/bundle}"
# download-artifact 解压丢 exec 位：-f 检查 + 落盘后 chmod（与 stage.sh 一致）
[ -f "$BUNDLE/voice_ui" ] || { echo "!! flutter bundle 缺失"; exit 1; }
mkdir -p "$STAGE/flutter-bundle"
cp -a "$BUNDLE/." "$STAGE/flutter-bundle/"
chmod +x "$STAGE/flutter-bundle/voice_ui"

cp "$SRC/packaging/tarball/install.sh" "$STAGE/install.sh"
chmod +x "$STAGE/install.sh"

PKG="$SRC/artifacts/packages/$NAME.tar.gz"
mkdir -p "$SRC/artifacts/packages"
tar -C /tmp/tarball -czf "$PKG" "$NAME"
echo ">> 产物: $PKG ($(du -h "$PKG" | cut -f1))"

# —— 冒烟：在当前容器装一遍（容器需有构建依赖；ubuntu 基座由外层装好）——
if command -v cmake >/dev/null 2>&1; then
    bash "$STAGE/install.sh" >/tmp/install.log 2>&1 || {
        echo "!! install.sh 失败"; tail -10 /tmp/install.log; exit 1; }
    bash "$SRC/packaging/common/smoke.sh"
else
    echo "[smoke] 跳过（容器无 cmake，CI 的 tarball 目标基座会装）"
fi
