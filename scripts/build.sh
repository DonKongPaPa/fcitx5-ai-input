#!/usr/bin/env bash
# 构建 addon（编译容器）+ Flutter JIT 资产（宿主 SDK——须与
# .cache/flutter-embedder/libflutter_engine.so 的引擎 hash 一致）+ testapp，
# 产物装入 artifacts/dist/
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${BUILD_IMAGE:-localhost/aiinput-build:latest}"

mkdir -p "$ROOT/artifacts/dist"

# —— Flutter 资产（宿主）：flutter build bundle（JIT）——
# 引擎 .so 是按宿主 SDK 的 engine hash 下载的（fetch-flutter-embedder.sh），
# kernel_blob 必须同一 SDK 产出，所以 flutter 构建留在宿主、不进容器
"$ROOT/scripts/fetch-sherpa-runtime.sh"
"$ROOT/scripts/fetch-flutter-embedder.sh"
(
    cd "$ROOT/flutter"
    flutter pub get >/dev/null
    flutter build bundle
)
FLUTTER_STAGE="$ROOT/artifacts/dist/share/fcitx5-aiinput/flutter"
rm -rf "$FLUTTER_STAGE"
mkdir -p "$FLUTTER_STAGE"
cp -r "$ROOT/flutter/build/flutter_assets" "$FLUTTER_STAGE/"
ICU="$("$ROOT/scripts/flutter-icu-path.sh")"
cp "$ICU" "$FLUTTER_STAGE/icudtl.dat"

# —— addon + testapp（编译容器）——
podman run --rm \
    --userns=keep-id \
    -v "$ROOT:/work" \
    -w /work \
    "$IMAGE" \
    bash -c '
        set -euxo pipefail
        # 在容器内 /tmp 构建，避免挂载卷时间戳导致 make 跳过重编
        cmake -S /work/addon -B /tmp/build-addon -DCMAKE_BUILD_TYPE=Release \
              -DCMAKE_INSTALL_PREFIX=/work/artifacts/dist \
              -DFLUTTER_ENGINE_LIBRARY=/work/.cache/flutter-embedder/libflutter_engine.so
        cmake --build /tmp/build-addon -j"$(nproc)"
        cmake --install /tmp/build-addon
        # testapp
        cmake -S /work/apps -B /tmp/build/apps -DCMAKE_BUILD_TYPE=Release \
              -DCMAKE_INSTALL_PREFIX=/work/artifacts/dist
        cmake --build /tmp/build/apps -j"$(nproc)"
        cmake --install /tmp/build/apps
        # virtpoint（wlr-virtual-pointer 注入工具，交互测试用）
        cmake -S /work/tools/virtpoint -B /tmp/build/virtpoint -DCMAKE_BUILD_TYPE=Release \
              -DCMAKE_INSTALL_PREFIX=/work/artifacts/dist
        cmake --build /tmp/build/virtpoint -j"$(nproc)"
        cmake --install /tmp/build/virtpoint
    '

# —— 构建自检（宿主机踩坑回归：陈旧 dist / 字体缺失 / 修复未编入）——
D="$ROOT/artifacts/dist"
check() { if eval "$2"; then echo "  ✓ $1"; else echo "  ✗ $1"; FAIL=1; fi; }
FAIL=0
check "CJK 字体在位（tofu 回归）" '[ -f "$D/share/fcitx5-aiinput/flutter/flutter_assets/assets/fonts/NotoSansSC-Regular.otf" ]'
check "popup compat 修复编入（SEGV 回归）" '[ "$(objdump -d "$D/lib/fcitx5/aiinput.so" | grep -c wl_proxy_set_user_data)" -ge 3 ]'
check "真实键形匹配编入（触发失效回归）" '[ "$(objdump -d "$D/lib/fcitx5/aiinput.so" | grep -c isModifier)" -ge 1 ]'
check "sherpa 引擎编入" '[ "$(objdump -d "$D/lib/fcitx5/aiinput.so" | grep -c SherpaOnnxCreateOnlineRecognizer)" -ge 1 ]'
check "引擎三件套在位" 'ls "$D/lib/fcitx5-aiinput/" | grep -q libsherpa-onnx-c-api.so && ls "$D/lib/fcitx5-aiinput/" | grep -q libonnxruntime.so && ls "$D/lib/fcitx5-aiinput/" | grep -q libflutter_engine.so'
[ "$FAIL" = 0 ] && echo ">> 构建自检全过" || { echo "!! 构建自检失败"; exit 1; }

echo ">> 产物："
find "$ROOT/artifacts/dist" -type f -o -type l | head -30
