#!/usr/bin/env bash
# 通用产物 staging（在各发行版容器内运行，容器已装好构建依赖）
# 产出 stage/ 目录：addon cmake 安装（含 libflutter_engine.so）+ Flutter JIT
# 资产（flutter_assets + icudtl.dat）+ funasr 服务脚本
# 环境变量：
#   SRC         源码根（默认 /work）
#   FLUTTER_ASSETS  预构建 flutter 资产目录（含 flutter_assets/ + icudtl.dat，
#                   默认 $SRC/artifacts/dist/share/fcitx5-voiceinput/flutter）
#   FLUTTER_ENGINE_LIBRARY  libflutter_engine.so（默认 $SRC/.cache/...）
set -euo pipefail
SRC="${SRC:-/work}"
STAGE="$SRC/packaging/out/stage"
rm -rf "$STAGE"

# Flutter 资产定位：CI 传入，或本地构建产物
FLUTTER_DIR="${FLUTTER_ASSETS:-$SRC/artifacts/dist/share/fcitx5-voiceinput/flutter}"
[ -d "$FLUTTER_DIR/flutter_assets" ] || { echo "!! flutter_assets 缺失: $FLUTTER_DIR"; exit 1; }
[ -f "$FLUTTER_DIR/icudtl.dat" ] || { echo "!! icudtl.dat 缺失: $FLUTTER_DIR"; exit 1; }

# 引擎 .so 定位（scripts/fetch-flutter-embedder.sh 下载）
ENGINE="${FLUTTER_ENGINE_LIBRARY:-$SRC/.cache/flutter-embedder/libflutter_engine.so}"
[ -f "$ENGINE" ] || { echo "!! libflutter_engine.so 缺失: $ENGINE（先跑 scripts/fetch-flutter-embedder.sh）"; exit 1; }

# 1. addon（cmake，安装到 stage/usr；引擎 .so 随 CMake install 规则装入
#    usr/lib/fcitx5-voiceinput/，rpath $ORIGIN/../fcitx5-voiceinput）
cmake -S "$SRC/addon" -B /tmp/build-pkg -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -DFLUTTER_ENGINE_LIBRARY="$ENGINE" \
      -DVOICEINPUT_FLUTTER_ASSETS_DIR="$FLUTTER_DIR"
cmake --build /tmp/build-pkg -j"$(nproc)"
DESTDIR="$STAGE" cmake --install /tmp/build-pkg

# 2. funasr 服务脚本 → libdir/fcitx5-voiceinput/（跟随发行版 libdir：
#    Debian lib/x86_64-linux-gnu、Fedora lib64、Arch lib——与引擎 .so 同目录）
LIBDIR="$(find "$STAGE/usr" -maxdepth 3 -type d -name fcitx5-voiceinput | head -1 | sed "s|^$STAGE/usr||")"
[ -n "$LIBDIR" ] || { echo "!! 找不到 libdir/fcitx5-voiceinput"; exit 1; }
mkdir -p "$STAGE/usr$LIBDIR/funasr-server"
cp "$SRC/scripts/funasr-server/server.py" "$STAGE/usr$LIBDIR/funasr-server/"
cp "$SRC/scripts/funasr-serve.sh" "$STAGE/usr$LIBDIR/funasr-server/"
chmod +x "$STAGE/usr$LIBDIR/funasr-server/funasr-serve.sh"
sed -i "s|ROOT=.*|ROOT=/usr$LIBDIR/fcitx5-voiceinput|" \
    "$STAGE/usr$LIBDIR/funasr-server/funasr-serve.sh" 2>/dev/null || true

# 3. 文档
mkdir -p "$STAGE/usr/share/doc/fcitx5-voice-input"
cp "$SRC/LICENSE" "$STAGE/usr/share/doc/fcitx5-voice-input/" 2>/dev/null || true

echo ">> staging 完成:"
find "$STAGE" -maxdepth 4 -type d | head -12
