#!/usr/bin/env bash
# card-qml 内存基准编排（宿主侧）：镜像复用 qml-probe（quickshell 已装），
# 挂 card-qml + lab，容器内跑 env/start-card-bench.sh，产物 OUT/card-perf.csv。
# 用法：containers/qml-probe/run-card-bench.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="localhost/aiinput-qml-probe:latest"

podman image exists "$IMAGE" || {
    echo "!! 先构建镜像：podman build -t $IMAGE -f containers/qml-probe/Containerfile.qml-probe containers/qml-probe/"
    exit 1
}

RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT="${AIINPUT_CARD_BENCH_OUT:-/tmp/aiinput-card-bench/$RUN_ID}"
mkdir -p "$OUT/logs"

DEV_ARGS=()
for d in /dev/dri/renderD*; do
    [ -e "$d" ] || continue
    DEV_ARGS+=(--device "$d")
    break
done

podman run --rm --user 0 --userns=keep-id \
    "${DEV_ARGS[@]}" \
    -v "$ROOT/containers/qml-probe:/probe:ro" \
    -v "$ROOT/card-qml:/card:ro" \
    -v "$ROOT/lab:/lab:ro" \
    -v "$OUT:/out" \
    -e LOG_DIR=/out/logs -e OUT_DIR=/out \
    "$IMAGE" \
    bash -c '
        set -e
        [ -s /etc/machine-id ] || printf "%s\n" "$(cat /proc/sys/kernel/random/uuid | tr -d -)" > /etc/machine-id
        chown testuser:testuser /out /out/logs 2>/dev/null || true
        su testuser -c "dbus-run-session -- bash /probe/env/start-card-bench.sh"
    '

echo ">> 产物：$OUT/card-perf.csv"
