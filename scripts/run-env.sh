#!/usr/bin/env bash
# 宿主机侧：在指定环境容器中运行编排脚本
# 用法：run-env.sh niri|kde|gnome [-- 额外podman参数或环境变量]
set -euo pipefail

ENV_NAME="${1:?用法: run-env.sh niri|kde|gnome}"
shift || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="localhost/voiceinput-${ENV_NAME}:latest"
OUT="$ROOT/artifacts/envcheck/${ENV_NAME}"
mkdir -p "$OUT"

podman run --rm \
    --userns=keep-id \
    -v "$ROOT/scripts:/scripts:ro" \
    -v "$ROOT/artifacts/dist:/opt/dist:ro" \
    -v "$OUT:/out" \
    -e LOG_DIR=/out/logs \
    -e OUT_DIR=/out \
    -e DURATION="${DURATION:-10}" \
    -e MODE="${MODE:-sleep}" \
    "$@" \
    "$IMAGE" \
    dbus-run-session -- bash "/scripts/env/start-${ENV_NAME}.sh"
