#!/usr/bin/env bash
# 通用产物 staging（在各发行版容器内运行，容器已装好构建依赖）
# 产出 stage/ 目录：addon cmake 安装 + 预编译 Flutter bundle + funasr 服务脚本
# 环境变量：
#   SRC         源码根（默认 /work）
#   FLUTTER_BUNDLE  预编译 flutter bundle 目录（默认 $SRC/artifacts/dist/.../bundle）
set -euo pipefail
SRC="${SRC:-/work}"
STAGE="$SRC/packaging/out/stage"
rm -rf "$STAGE"

# flutter bundle 定位：CI 传入，或本地构建产物
BUNDLE="${FLUTTER_BUNDLE:-$SRC/artifacts/dist/lib/fcitx5-voiceinput/ui/bundle}"
# CI 的 download-artifact 解压可能丢 exec 位：只查存在，拷贝后强制 chmod
[ -f "$BUNDLE/voice_ui" ] || { echo "!! flutter bundle 缺失: $BUNDLE"; exit 1; }
ls -la "$BUNDLE" | head -6

# 1. addon（cmake，安装到 stage/usr）
cmake -S "$SRC/addon" -B /tmp/build-pkg -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr
cmake --build /tmp/build-pkg -j"$(nproc)"
DESTDIR="$STAGE" cmake --install /tmp/build-pkg

# 2. flutter bundle → /usr/lib/fcitx5-voiceinput/ui/bundle
mkdir -p "$STAGE/usr/lib/fcitx5-voiceinput/ui"
cp -r "$BUNDLE" "$STAGE/usr/lib/fcitx5-voiceinput/ui/bundle"
chmod +x "$STAGE/usr/lib/fcitx5-voiceinput/ui/bundle/voice_ui"

# 3. funasr 服务脚本 → /usr/lib/fcitx5-voiceinput/
mkdir -p "$STAGE/usr/lib/fcitx5-voiceinput/funasr-server"
cp "$SRC/scripts/funasr-server/server.py" "$STAGE/usr/lib/fcitx5-voiceinput/funasr-server/"
cp "$SRC/scripts/funasr-serve.sh" "$STAGE/usr/lib/fcitx5-voiceinput/funasr-server/"
chmod +x "$STAGE/usr/lib/fcitx5-voiceinput/funasr-server/funasr-serve.sh"
sed -i 's|ROOT=.*|ROOT=/usr/lib/fcitx5-voiceinput|' \
    "$STAGE/usr/lib/fcitx5-voiceinput/funasr-server/funasr-serve.sh" 2>/dev/null || true

# 4. 文档
mkdir -p "$STAGE/usr/share/doc/fcitx5-voice-input"
cp "$SRC/LICENSE" "$STAGE/usr/share/doc/fcitx5-voice-input/" 2>/dev/null || true

echo ">> staging 完成:"
find "$STAGE" -maxdepth 4 -type d | head -12
