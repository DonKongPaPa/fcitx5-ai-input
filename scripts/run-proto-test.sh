#!/usr/bin/env bash
# proto-test 容器（快档）：协议 v1 对拍——schema 结构+事件参数+跨通道
# 不变量，秒级。镜像复用 aiinput-base（纯标准库，零依赖）。触发：改
# lab/spec/ 协议或回放脚本后。用法：make proto-test
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="localhost/aiinput-base:latest"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/artifacts/prototest/$RUN_ID"
mkdir -p "$OUT"

podman image exists "$IMAGE" || { echo "!! 先 make image-base"; exit 1; }
podman run --rm --userns=keep-id \
    -v "$ROOT/lab:/lab:ro" \
    -v "$OUT:/out" \
    localhost/aiinput-base:latest \
    python3 /lab/spec/proto_check.py --out /out/proto-report.json /lab/spec/events
echo ">> proto-test 完成：$OUT/proto-report.json"
