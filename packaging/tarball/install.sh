#!/usr/bin/env bash
# fcitx5-voice-input 通用安装脚本（tarball）
# 自带预编译 Flutter bundle；addon 本体在本机用 cmake 构建（需要构建依赖：
# gcc/cmake/fcitx5 开发头/wayland-scanner）
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr}"

echo ">> 构建 addon（需要 gcc cmake fcitx5-dev wayland-dev gettext）"
cmake -S "$HERE/addon" -B /tmp/voiceinput-build -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PREFIX"
cmake --build /tmp/voiceinput-build -j"$(nproc)"
DESTDIR="" cmake --install /tmp/voiceinput-build

echo ">> 安装 Flutter UI bundle → $PREFIX/lib/fcitx5-voiceinput/ui/bundle"
mkdir -p "$PREFIX/lib/fcitx5-voiceinput/ui"
cp -a "$HERE/flutter-bundle" "$PREFIX/lib/fcitx5-voiceinput/ui/bundle"

echo ">> 安装 funasr 服务脚本 → $PREFIX/lib/fcitx5-voiceinput/funasr-server"
mkdir -p "$PREFIX/lib/fcitx5-voiceinput/funasr-server"
cp "$HERE/scripts/funasr-server/server.py" "$PREFIX/lib/fcitx5-voiceinput/funasr-server/"
cp "$HERE/scripts/funasr-serve.sh" "$PREFIX/lib/fcitx5-voiceinput/funasr-server/"
chmod +x "$PREFIX/lib/fcitx5-voiceinput/funasr-server/funasr-serve.sh"

echo ">> 完成。设置：fcitx5-configtool → 附加组件 → Voice Input"
echo ">> 语音服务：$PREFIX/lib/fcitx5-voiceinput/funasr-server/funasr-serve.sh start"
echo ">>（或 configtool 里开 FunASRAutoStart 自动拉起）"
