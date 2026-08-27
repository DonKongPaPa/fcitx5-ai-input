#!/usr/bin/env bash
# fcitx5-ai-input 通用安装脚本（tarball）
# 自带 Flutter JIT 资产 + raw embedder 引擎 .so + sherpa-onnx 运行时；
# addon 本体在本机用 cmake 构建（需要构建依赖：gcc/cmake/fcitx5 开发头/
# wayland-scanner/fontconfig 开发包）
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr}"

echo ">> 构建 addon（需要 gcc cmake fcitx5-dev wayland-dev fontconfig-dev libxcb-dev gettext）"
cmake -S "$HERE/addon" -B /tmp/aiinput-build -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DFLUTTER_ENGINE_LIBRARY="$HERE/engine/libflutter_engine.so" \
      -DSHERPA_ONNX_LIBRARY="$HERE/engine/libsherpa-onnx-c-api.so" \
      -DAIINPUT_FLUTTER_ASSETS_DIR="$HERE/flutter-ui"
cmake --build /tmp/aiinput-build -j"$(nproc)"
DESTDIR="" cmake --install /tmp/aiinput-build

echo ">> 安装 Flutter 资产 → $PREFIX/share/fcitx5-aiinput/flutter"
mkdir -p "$PREFIX/share/fcitx5-aiinput/flutter"
cp -a "$HERE/flutter-ui/flutter_assets" "$PREFIX/share/fcitx5-aiinput/flutter/"
cp "$HERE/flutter-ui/icudtl.dat" "$PREFIX/share/fcitx5-aiinput/flutter/"

echo ">> 安装 funasr 服务脚本 → $PREFIX/lib/fcitx5-aiinput/funasr-server"
mkdir -p "$PREFIX/lib/fcitx5-aiinput/funasr-server"
cp "$HERE/scripts/funasr-server/server.py" "$PREFIX/lib/fcitx5-aiinput/funasr-server/"
cp "$HERE/scripts/funasr-serve.sh" "$PREFIX/lib/fcitx5-aiinput/funasr-server/"
chmod +x "$PREFIX/lib/fcitx5-aiinput/funasr-server/funasr-serve.sh"

echo ">> 完成。无需切换输入法：任何 IM（rime/pinyin…）激活时长按右 Ctrl 即可语音输入"
echo ">> 设置：fcitx5-configtool → 附加组件 → Voice Input"
echo ">> 语音服务：$PREFIX/lib/fcitx5-aiinput/funasr-server/funasr-serve.sh start"
echo ">>（或 configtool 里开 FunASRAutoStart 自动拉起）"
