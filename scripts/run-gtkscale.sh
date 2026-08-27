#!/usr/bin/env bash
# gtkscale 诊断编排（宿主侧）：诊断容器双 scale 跑一轮，产物 artifacts/gtkscale/
# 用法：scripts/run-gtkscale.sh [scale ...]（默认 1.0 2.0）
# 镜像：Containerfile.gtkscale（niri 环境 + fcitx5-gtk 显式确保 + xwininfo/xprop）
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="localhost/aiinput-gtkscale:latest"

podman image exists "$IMAGE" || {
    echo "!! 镜像缺失：podman build -t $IMAGE -f containers/Containerfile.gtkscale containers/"
    exit 1
}
[ -d "$ROOT/artifacts/dist/lib/fcitx5" ] || { echo "!! 先 make build（artifacts/dist 缺失）"; exit 1; }

# 直通首个渲染节点即可（run-test.sh 同款：多节点反致 wlroots 跨 GPU 拷贝失败）
DEV_ARGS=()
for d in /dev/dri/renderD*; do
    [ -e "$d" ] || continue
    DEV_ARGS+=(--device "$d")
    break
done

SCALES=("$@")
[ ${#SCALES[@]} -eq 0 ] && SCALES=(1.0 2.0)

for SCALE in "${SCALES[@]}"; do
    RUN_ID="gtkscale-$(date +%Y%m%d-%H%M%S)-$SCALE"
    OUT="$ROOT/artifacts/gtkscale/$RUN_ID"
    mkdir -p "$OUT/logs"
    echo ">> scale=$SCALE → $OUT"
    podman run --rm \
        --user 0 --userns=keep-id \
        "${DEV_ARGS[@]}" \
        -v "$ROOT/scripts:/scripts:ro" \
        -v "$ROOT/artifacts/dist:/opt/dist:ro" \
        -v "$OUT:/out" \
        -e ENV_NAME=niri \
        -e NIRI_TEST_SCALE="$SCALE" \
        -e MODE=case \
        -e CASE_DRIVER=/scripts/env/gtkscale-driver.sh \
        -e LOG_DIR=/out/logs \
        -e OUT_DIR=/out \
        "$IMAGE" \
        bash -c '
            set -e
            [ -s /etc/machine-id ] || printf "%s\n" "$(cat /proc/sys/kernel/random/uuid | tr -d -)" > /etc/machine-id
            cp -r /opt/dist/* /usr/
            mkdir -p /home/testuser/.config/fcitx5
            printf "[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=keyboard-us\n\n[Groups/0/Items/0]\nName=keyboard-us\n\n[Groups/0/Items/1]\nName=pinyin\n\n[Group Order]\n0=Default\n" \
                > /home/testuser/.config/fcitx5/profile
            chown -R testuser:testuser /home/testuser/.config
            chown testuser:testuser /out /out/logs 2>/dev/null || true
            fcitx5 --version > /out/env-info.txt 2>&1 || true
            su testuser -c "dbus-run-session -- bash /scripts/env/start-niri.sh"
        '
    echo ">> 产物：$OUT"
    [ -s "$OUT/summary.txt" ] && cat "$OUT/summary.txt"
done
