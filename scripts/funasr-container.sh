#!/usr/bin/env bash
# funasr 服务的容器编排（测试自含形态；产品用宿主 funasr-serve.sh）
# 用法:
#   funasr-container.sh start-gpu          # funasr-gpu 容器 :10095（GPU 直通）
#   funasr-container.sh start-cpu [quant]  # funasr-cpu 容器 :10096（默认 int8）
#   funasr-container.sh status | stop      # stop = 全量销毁，不留常驻
# 容器网 aiinput-net：被测 niri 容器经 DNS 名 funasr-gpu/funasr-cpu 访问；
# 同时 publish 到宿主 127.0.0.1 供冒烟计时。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="localhost/aiinput-funasr:latest"
NET="aiinput-net"
EXP="$ROOT/experiments/001-funasr-nano-local"
DATA="$EXP/data"
LOG_DIR="$ROOT/artifacts"
mkdir -p "$LOG_DIR"

MODEL_DIR="$(find "$DATA/modelscope" -maxdepth 5 -type d \
    -path '*Fun-ASR-MLT-Nano*/snapshots/master' 2>/dev/null | head -1)"
REMOTE_CODE="$DATA/Fun-ASR-code/model.py"
[ -n "$MODEL_DIR" ] || { echo "!! 模型未找到（$DATA/modelscope）"; exit 1; }
# 卷挂载 $DATA→/data：env 传容器侧路径
MODEL_DIR="${MODEL_DIR/#$DATA//data}"
REMOTE_CODE="/data/Fun-ASR-code/model.py"

ensure_net() {
    podman network inspect "$NET" >/dev/null 2>&1 || podman network create "$NET"
}

# GPU 裸直通（免 sudo，实验 001 run-matrix 同款）：设备 + 宿主驱动库软链
gpu_args() {
    local nvidia_ver dev
    nvidia_ver="$(basename "$(readlink -f /usr/lib/libcuda.so.1)" | sed 's/.*so\.//')"
    [ -e /dev/nvidia0 ] && [ -n "$nvidia_ver" ] || { echo "无 GPU 直通条件"; return 1; }
    GPU_ARGS=(--device /dev/nvidia0 --device /dev/nvidiactl
              --device /dev/nvidia-uvm --device /dev/nvidia-modeset)
    for lib in libcuda libnvidia-ml libnvidia-ptxjitcompiler libnvidia-rtcore libnvidia-nvjitlink; do
        local src="/usr/lib/${lib}.so.${nvidia_ver}"
        [ -e "$src" ] || continue
        GPU_ARGS+=(-v "$src:/usr/lib/${lib}.so.${nvidia_ver}:ro")
        GPU_SETUP+="ln -sf /usr/lib/${lib}.so.${nvidia_ver} /usr/lib/${lib}.so.1; "
    done
    return 0
}

start() {  # $1=name $2=host_port $3=额外参数…
    local name="$1" port="$2"; shift 2
    ensure_net
    if podman container exists "$name"; then
        echo ">> $name 已存在（$(podman inspect -f '{{.State.Status}}' "$name")）"
        return 0
    fi
    podman run -d --name "$name" \
        --network "$NET" \
        -p "127.0.0.1:${port}:10095" \
        -v "$DATA:/data:ro" \
        -e MODEL_DIR="$MODEL_DIR" -e REMOTE_CODE="$REMOTE_CODE" \
        "$@" \
        "$IMAGE" \
        bash -c "${GPU_SETUP:-}"' exec python /opt/aiinput/server.py \
            --host 0.0.0.0 --port 10095 \
            --model-dir "$MODEL_DIR" --remote-code "$REMOTE_CODE" '"$EXTRA_OPTS"
    echo ">> $name 启动（日志: podman logs $name）"
}

case "${1:-status}" in
start-gpu)
    GPU_ARGS=() GPU_SETUP=""
    gpu_args || exit 1
    EXTRA_OPTS="" start funasr-gpu 10095 "${GPU_ARGS[@]}"
    ;;
start-cpu)
    EXTRA_OPTS="--device cpu --quant ${2:-int8}"
    GPU_SETUP="" GPU_ARGS=()
    start funasr-cpu 10096
    ;;
stop)
    podman rm -f funasr-gpu funasr-cpu >/dev/null 2>&1 || true
    echo ">> funasr 容器已全部销毁"
    ;;
status)
    for c in funasr-gpu funasr-cpu; do
        if podman container exists "$c"; then
            echo "$c: $(podman inspect -f '{{.State.Status}}' "$c")  $(podman logs --tail 1 "$c" 2>&1 | tail -c 120)"
        else
            echo "$c: 不存在"
        fi
    done
    ;;
*) echo "用法: $0 start-gpu|start-cpu [quant]|status|stop"; exit 1 ;;
esac
