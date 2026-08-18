#!/usr/bin/env bash
# F7 宿主编排（全容器形态，宿主不跑模型）：
#   funasr-gpu / funasr-cpu 容器（voiceinput-net）→ niri 容器跑 f7-test.sh
#   → VRAM/RSS 采样 → 销毁全部 funasr 容器（不留常驻）
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/artifacts/f7"
mkdir -p "$OUT"

echo "== 1. funasr 服务容器"
bash "$ROOT/scripts/funasr-container.sh" start-gpu
bash "$ROOT/scripts/funasr-container.sh" start-cpu int8

wait_container_listen() {  # $1=容器名
    for _ in $(seq 1 150); do
        [ -n "$(podman logs "$1" 2>&1 | grep -a 'listening on')" ] && return 0
        sleep 1
    done
    return 1
}
echo -n "等待 GPU 容器就绪… "; wait_container_listen funasr-gpu && echo ok || { echo 超时; exit 1; }
echo -n "等待 CPU 容器就绪（含 int8 量化）… "; wait_container_listen funasr-cpu && echo ok || { echo 超时; exit 1; }
podman logs funasr-gpu 2>&1 | grep -a "模型加载完成" | tail -1 | sed 's/^/  GPU /'
podman logs funasr-cpu 2>&1 | grep -a "模型加载完成" | tail -1 | sed 's/^/  CPU /'

echo "== 2. 两档识别冒烟计时（容器 publish 端口）"
cat > "$OUT/smoke-timing.py" <<'EOF'
import asyncio, json, sys, time, wave
import websockets
async def main(port):
    wf = wave.open('artifacts/voice-samples/中文测试-16k.wav', 'rb')
    pcm = wf.readframes(wf.getnframes())
    async with websockets.connect(f'ws://127.0.0.1:{port}', max_size=None) as ws:
        t0 = time.time(); first = None
        for i in range(0, len(pcm), 3200):
            await ws.send(pcm[i:i+3200]); await asyncio.sleep(0.05)
            while True:
                try:
                    j = json.loads(await asyncio.wait_for(ws.recv(), timeout=0.01))
                    if j.get('text') and first is None: first = time.time()-t0
                except asyncio.TimeoutError: break
        await ws.send(json.dumps({'is_speaking': False}))
        while True:
            j = json.loads(await ws.recv())
            if j.get('is_final'):
                print(f"{port} first_partial={first:.2f}s final={time.time()-t0:.2f}s text={j['text']}")
                return
asyncio.run(main(int(sys.argv[1])))
EOF
( cd "$ROOT" && .funasr-env/bin/python "$OUT/smoke-timing.py" 10095 | tee "$OUT/gpu-timing.txt" )
( cd "$ROOT" && .funasr-env/bin/python "$OUT/smoke-timing.py" 10096 | tee "$OUT/cpu-timing.txt" )

echo "== 3. 容器 f7（configtool 深测 + 两档核心场景；niri 容器加入 voiceinput-net）"
DEV_ARGS=()
for d in /dev/dri/renderD*; do
    [ -e "$d" ] && DEV_ARGS+=(--device "$d") && break
done
EXP="$ROOT/experiments/001-funasr-nano-local"
timeout 420 podman run --rm \
    --user 0 --userns=keep-id "${DEV_ARGS[@]}" \
    --network voiceinput-net \
    -v "$ROOT/scripts:/scripts:ro" \
    -v "$ROOT/artifacts/dist:/opt/dist:ro" \
    -v "$ROOT/artifacts/voice-samples:/samples:ro" \
    -v "$EXP/data/llamacpp:/usr/lib/fcitx5-voiceinput/llamacpp:ro" \
    -v "$EXP/data/gguf:/usr/lib/fcitx5-voiceinput/gguf:ro" \
    -v "$OUT:/out" \
    -e FUNASR_URL_GPU=ws://funasr-gpu:10095 \
    -e FUNASR_URL_CPU=ws://funasr-cpu:10095 \
    localhost/voiceinput-niri:latest \
    bash -c '
        cp -r /opt/dist/* /usr/ || true
        mkdir -p /tmp/dbus-masked
        mv /usr/share/dbus-1/services/org.fcitx.Fcitx5.service /tmp/dbus-masked/ 2>/dev/null || true
        mkdir -p /home/testuser/.config/fcitx5
        printf "[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=voiceinput\n\n[Groups/0/Items/0]\nName=voiceinput\nLayout=\n\n[Group Order]\n0=Default\n" > /home/testuser/.config/fcitx5/profile
        chown -R testuser:testuser /home/testuser/.config
        chown testuser:testuser /out 2>/dev/null || true
        su testuser -c "dbus-run-session -- bash /scripts/env/f7-test.sh" > /tmp/f7-out.log 2>&1 || true
        cp /tmp/f7.mp4 /tmp/fcitx5.log /tmp/f7-out.log /tmp/configtool.log /out/ 2>/dev/null || true
        chmod 644 /out/* 2>/dev/null || true
        kill -9 -1 2>/dev/null || true
    ' >/dev/null 2>&1
grep -aE "^S[0-9]|✓|✗|F7 结果|耗时|全部通过|存在失败" "$OUT/f7-out.log"
# 注意：此处不 rm -fa——测试容器 --rm 自删，funasr 容器留着给第 4 步采样

echo "== 4. 资源采样"
# 宿主已无其他 GPU 计算进程（步骤0 清理），总量即 funasr-gpu 占用
GPU_VRAM=$(nvidia-smi --query-compute-apps=used_memory --format=csv,noheader 2>/dev/null \
    | awk '{s+=$1} END {print (s?NR" 进程共 "s" MiB":"未见")}')
CPU_RSS=$(podman stats --no-stream --format "{{.MemUsage}}" funasr-cpu 2>/dev/null | awk '{print $1}')
echo "funasr-gpu VRAM=$GPU_VRAM | funasr-cpu(int8) RSS=$CPU_RSS"
{
  echo "## F7 部署矩阵数据（全容器形态）"
  echo "- GPU: $(cat "$OUT/gpu-timing.txt" 2>/dev/null) VRAM=$GPU_VRAM"
  echo "- CPU int8: $(cat "$OUT/cpu-timing.txt" 2>/dev/null) RSS=$CPU_RSS"
} > "$OUT/matrix.md"

echo "== 5. 销毁 funasr 容器（不留常驻）"
bash "$ROOT/scripts/funasr-container.sh" stop
echo "完成。数据：$OUT/matrix.md"
