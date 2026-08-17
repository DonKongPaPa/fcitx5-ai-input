#!/usr/bin/env bash
# 在编译容器中构建 addon（后续接入 flutter / testapp），产物装入 artifacts/dist/
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${BUILD_IMAGE:-localhost/voiceinput-build:latest}"

mkdir -p "$ROOT/artifacts/dist"

podman run --rm \
    --userns=keep-id \
    -v "$ROOT:/work" \
    -w /work \
    "$IMAGE" \
    bash -c '
        set -euxo pipefail
        # 在容器内 /tmp 构建，避免挂载卷时间戳导致 make 跳过重编
        cmake -S /work/addon -B /tmp/build-addon -DCMAKE_BUILD_TYPE=Release \
              -DCMAKE_INSTALL_PREFIX=/work/artifacts/dist
        cmake --build /tmp/build-addon -j"$(nproc)"
        cmake --install /tmp/build-addon
        cmake -S apps -B build/apps -DCMAKE_BUILD_TYPE=Release \
              -DCMAKE_INSTALL_PREFIX=/work/artifacts/dist
        cmake --build build/apps -j"$(nproc)"
        cmake --install build/apps
    '

echo ">> 产物："
find "$ROOT/artifacts/dist" -type f -o -type l | head -50
