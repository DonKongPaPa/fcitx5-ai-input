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
        cmake -S addon -B build/addon -DCMAKE_BUILD_TYPE=Release \
              -DCMAKE_INSTALL_PREFIX=/work/artifacts/dist
        cmake --build build/addon -j"$(nproc)"
        cmake --install build/addon
    '

echo ">> 产物："
find "$ROOT/artifacts/dist" -type f -o -type l | head -50
