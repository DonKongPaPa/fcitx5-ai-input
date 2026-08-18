#!/usr/bin/env bash
# 宿主侧 FunASR 流式服务管理（原生 GPU，无容器）
# 用法: funasr-serve.sh start|stop|status|log
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$ROOT/.funasr-env"
PID_FILE="$ROOT/artifacts/funasr-serve.pid"
LOG="$ROOT/artifacts/funasr-serve.log"
PORT="${FUNASR_PORT:-10095}"
DEVICE="${FUNASR_DEVICE:-auto}"

MODEL_DIR="$(find "$ROOT/experiments/001-funasr-nano-local/data/modelscope" \
    -maxdepth 5 -type d -path '*Fun-ASR-MLT-Nano*/snapshots/master' 2>/dev/null | head -1)"
REMOTE_CODE="$ROOT/experiments/001-funasr-nano-local/data/Fun-ASR-code/model.py"

mkdir -p "$ROOT/artifacts"

ensure_venv() {
    if [ ! -x "$VENV/bin/python" ]; then
        echo ">> 创建 venv（python 3.12，规避宿主 3.14 轮子风险）"
        uv venv --python 3.12 "$VENV"
        echo ">> 安装 funasr/torch/websockets（TUNA 源，torch 为 CUDA 合包，一次 ~3GB）"
        UV_INDEX_URL="${UV_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}" \
            uv pip install --python "$VENV/bin/python" funasr websockets
    fi
}

is_up() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

case "${1:-status}" in
start)
    if is_up; then echo "已在运行 pid=$(cat "$PID_FILE")"; exit 0; fi
    ensure_venv
    [ -n "$MODEL_DIR" ] || { echo "!! 模型未找到（experiments/001 data/modelscope）"; exit 1; }
    dev_args=()
    [ "$DEVICE" != "auto" ] && dev_args=(--device "$DEVICE")
    echo ">> 启动 funasr-serve :$PORT device=$DEVICE model=${MODEL_DIR#$ROOT/}"
    nohup "$VENV/bin/python" "$ROOT/scripts/funasr-server/server.py" \
        --port "$PORT" "${dev_args[@]}" \
        --model-dir "$MODEL_DIR" --remote-code "$REMOTE_CODE" \
        >> "$LOG" 2>&1 &
    echo $! > "$PID_FILE"
    echo ">> pid=$(cat "$PID_FILE") 日志: $LOG（模型加载 ~10-20s）"
    ;;
stop)
    if is_up; then
        kill "$(cat "$PID_FILE")" && echo ">> 已停止"
        rm -f "$PID_FILE"
    else
        echo "未在运行"
    fi
    ;;
status)
    if is_up; then
        echo "running pid=$(cat "$PID_FILE") port=$PORT"
        tail -2 "$LOG" 2>/dev/null || true
    else
        echo "stopped"
    fi
    ;;
log) tail -f "$LOG" ;;
*) echo "用法: $0 start|stop|status|log"; exit 1 ;;
esac
