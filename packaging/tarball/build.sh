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
    apt-get install -y -qq --no-install-recommends         build-essential cmake pkg-config gettext git dbus         libfcitx5core-dev libfcitx5utils-dev libfcitx5config-dev         fcitx5-modules-dev fcitx5 libwayland-dev libwayland-bin         libfontconfig1-dev pulseaudio-utils libglib2.0-bin >/dev/null 2>&1 || true
fi

NAME="fcitx5-ai-input-$VERSION"
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

# Flutter JIT 资产 + raw embedder 引擎 .so + sherpa-onnx 运行时（自带，
# 免安装期下载）
FLUTTER_DIR="${FLUTTER_ASSETS:-$SRC/artifacts/dist/share/fcitx5-aiinput/flutter}"
ENGINE="${FLUTTER_ENGINE_LIBRARY:-$SRC/.cache/flutter-embedder/libflutter_engine.so}"
SHERPA_CAPI="${SHERPA_ONNX_LIBRARY:-$SRC/.cache/sherpa-onnx/libsherpa-onnx-c-api.so}"
[ -d "$FLUTTER_DIR/flutter_assets" ] || { echo "!! flutter_assets 缺失: $FLUTTER_DIR"; exit 1; }
[ -f "$FLUTTER_DIR/icudtl.dat" ] || { echo "!! icudtl.dat 缺失"; exit 1; }
[ -f "$ENGINE" ] || { echo "!! libflutter_engine.so 缺失（跑 scripts/fetch-flutter-embedder.sh）"; exit 1; }
[ -f "$SHERPA_CAPI" ] || { echo "!! libsherpa-onnx-c-api.so 缺失（跑 scripts/fetch-sherpa-runtime.sh）"; exit 1; }
mkdir -p "$STAGE/flutter-ui" "$STAGE/engine"
cp -a "$FLUTTER_DIR/flutter_assets" "$STAGE/flutter-ui/"
cp "$FLUTTER_DIR/icudtl.dat" "$STAGE/flutter-ui/"
cp "$ENGINE" "$STAGE/engine/"
cp "$SHERPA_CAPI" "$STAGE/engine/"
cp "$(dirname "$SHERPA_CAPI")/libonnxruntime.so" "$STAGE/engine/"

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
