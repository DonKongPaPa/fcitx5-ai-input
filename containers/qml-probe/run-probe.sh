#!/usr/bin/env bash
# qml-probe 探针编排（宿主侧）：构建/复用镜像 → 单容器跑一轮探针 → 打印断言。
# 产物默认 /tmp/aiinput-qml-probe/<ts>/（AIINPUT_QML_PROBE_OUT 可覆盖）。
# 用法：containers/qml-probe/run-probe.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="localhost/aiinput-qml-probe:latest"

# 镜像缺失时现场构建（也可手动：
#   podman build -t localhost/aiinput-qml-probe:latest \
#       -f containers/qml-probe/Containerfile.qml-probe containers/qml-probe/ ）
podman image exists "$IMAGE" || {
    echo ">> 镜像缺失，构建 $IMAGE（Containerfile.qml-probe）"
    podman build -t "$IMAGE" \
        -f "$ROOT/containers/qml-probe/Containerfile.qml-probe" \
        "$ROOT/containers/qml-probe"
}

RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT="${AIINPUT_QML_PROBE_OUT:-/tmp/aiinput-qml-probe/$RUN_ID}"
mkdir -p "$OUT/logs"

# 直通首个渲染节点即可（run-gtkscale.sh 同款：多节点反致 wlroots 跨 GPU 拷贝失败）
DEV_ARGS=()
for d in /dev/dri/renderD*; do
    [ -e "$d" ] || continue
    DEV_ARGS+=(--device "$d")
    break
done

podman run --rm --user 0 --userns=keep-id \
    "${DEV_ARGS[@]}" \
    -v "$ROOT/containers/qml-probe:/probe:ro" \
    -v "$ROOT/lab:/lab:ro" \
    -v "$OUT:/out" \
    -e LOG_DIR=/out/logs -e OUT_DIR=/out \
    "$IMAGE" \
    bash -c '
        set -e
        [ -s /etc/machine-id ] || printf "%s\n" "$(cat /proc/sys/kernel/random/uuid | tr -d -)" > /etc/machine-id
        chown testuser:testuser /out /out/logs 2>/dev/null || true
        su testuser -c "dbus-run-session -- bash /probe/env/start-probe.sh"
    '

echo ">> 产物：$OUT"
[ -s "$OUT/summary.txt" ] && cat "$OUT/summary.txt"
