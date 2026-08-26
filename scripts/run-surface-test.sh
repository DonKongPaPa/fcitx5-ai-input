#!/usr/bin/env bash
# surface-test 容器（快档·根因分析工具）：单场景一容器（sway 1080p），
# 双引擎定位测量 + 差分 bbox + HTML 并排报告 + 标注图素材。
# 用法：make surface-test SC=S4   或  ./scripts/run-surface-test.sh S4
# 场景：S1 gtk左列 S2 gtk长文本 S3 gtk右列 S4 qt-dbus铺满 S5 qt-dbus右列
#       S6 chromium
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="localhost/aiinput-niri:latest"
SC="${1:-${SC:-S1}}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/artifacts/surfacetest/${SC}-${RUN_ID}"
mkdir -p "$OUT/logs"

[ -d "$ROOT/artifacts/dist/lib/fcitx5" ] || { echo "!! 先 make build"; exit 1; }
podman image exists "$IMAGE" || { echo "!! 先 make image-niri"; exit 1; }

DEV_ARGS=()
for d in /dev/dri/renderD*; do [ -e "$d" ] && DEV_ARGS+=(--device "$d") && break; done

podman run --rm --user 0 --userns=keep-id \
    "${DEV_ARGS[@]}" \
    -v "$ROOT/scripts:/scripts:ro" \
    -v "$ROOT/lab:/lab:ro" \
    -v "$ROOT/artifacts/dist:/opt/dist:ro" \
    -v "$OUT:/out" \
    -e MODE=surface -e SURFACE_SCENARIO="$SC" \
    -e LOG_DIR=/out/logs -e OUT_DIR=/out \
    "$IMAGE" \
    bash -c '
        set -e
        [ -s /etc/machine-id ] || printf "%s\n" "$(cat /proc/sys/kernel/random/uuid | tr -d -)" > /etc/machine-id
        cp -r /opt/dist/* /usr/
        mkdir -p /home/testuser/.config/fcitx5
        printf "[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=keyboard-us\n\n[Groups/0/Items/0]\nName=keyboard-us\n\n[Groups/0/Items/1]\nName=pinyin\n\n[Group Order]\n0=Default\n" > /home/testuser/.config/fcitx5/profile
        chown -R testuser:testuser /home/testuser/.config /out 2>/dev/null || true
        fcitx5 --version > /out/env-info.txt 2>&1 || true
        su testuser -c "dbus-run-session -- bash /scripts/env/start-niri.sh"
    '
echo ">> 报告：$OUT/surface-report.html（标注图/探针素材同目录）"
