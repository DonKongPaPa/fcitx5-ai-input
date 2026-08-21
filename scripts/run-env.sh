#!/usr/bin/env bash
# 宿主机侧：在指定环境容器中运行编排脚本
# 用法：run-env.sh niri|kde|gnome [-- 额外podman参数或环境变量]
set -euo pipefail

ENV_NAME="${1:?用法: run-env.sh niri|kde|gnome}"
shift || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="localhost/aiinput-${ENV_NAME}:latest"
OUT="$ROOT/artifacts/envcheck/${ENV_NAME}"
mkdir -p "$OUT"

# 直通宿主机 GPU 渲染节点（只传第一个）：
# - 传多个渲染节点会导致 wlroots(cage/sway) 跨 GPU dmabuf 拷贝失败
#   （双显卡机器上 NVIDIA 节点参与时 screencopy 报 Failed to copy frame）
# - kwin 用 KWIN_COMPOSE=Q 软件渲染后不再强求第二个节点
DEV_MODE="${DEV_MODE:-first}"
DEV_ARGS=()
for d in /dev/dri/renderD*; do
    [ -e "$d" ] || continue
    DEV_ARGS+=(--device "$d")
    [ "$DEV_MODE" = "first" ] && break
done
DEV_ARGS=()
for d in /dev/dri/renderD*; do
    [ -e "$d" ] || continue
    DEV_ARGS+=(--device "$d")
    [ "$DEV_MODE" = "first" ] && break
done

podman run --rm \
    --userns=keep-id \
    "${DEV_ARGS[@]}" \
    -v "$ROOT/scripts:/scripts:ro" \
    -v "$ROOT/artifacts/dist:/opt/dist:ro" \
    -v "$OUT:/out" \
    -e LOG_DIR=/out/logs \
    -e OUT_DIR=/out \
    -e DURATION="${DURATION:-10}" \
    -e MODE="${MODE:-sleep}" \
    -e ENABLE_STACK="${ENABLE_STACK:-1}" \
    "$@" \
    "$IMAGE" \
    dbus-run-session -- bash "/scripts/env/start-${ENV_NAME}.sh"
