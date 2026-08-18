#!/usr/bin/env bash
# F7 宿主编排：起 GPU/CPU 两档 funasr 服务 → 容器跑 f7-test.sh → 采样 → 汇总
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/artifacts/f7"
mkdir -p "$OUT"

echo "== 1. 服务实例"
bash "$ROOT/scripts/funasr-serve.sh" start >/dev/null   # GPU :10095（幂等）
GPU_PID=$(cat "$ROOT/artifacts/funasr-serve.pid")
FUNASR_PORT=10096 FUNASR_DEVICE=cpu FUNASR_QUANT=int8 \
    bash "$ROOT/scripts/funasr-serve.sh" start
CPU_PID=$(cat "$ROOT/artifacts/funasr-serve-10096.pid")

wait_listen() {  # $1=log $2=grep 模式
    for _ in $(seq 1 120); do
        grep -aq "$2" "$1" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}
echo -n "等待 GPU 实例… "
wait_listen "$ROOT/artifacts/funasr-serve.log" "listening.*10095" && echo ok || { echo 超时; exit 1; }
echo -n "等待 CPU 实例（含 int8 量化，~60-90s）… "
wait_listen "$ROOT/artifacts/funasr-serve-10096.log" "listening.*10096" && echo ok || { echo 超时; exit 1; }
grep -a "模型加载完成" "$ROOT/artifacts/funasr-serve.log" | tail -1 | sed 's/^/  GPU: /'
grep -a "模型加载完成" "$ROOT/artifacts/funasr-serve-10096.log" | tail -1 | sed 's/^/  CPU: /'

echo "== 2. 两档识别冒烟计时（宿主直连）"
cat > "$OUT/smoke-timing.py" <<'EOF'
import asyncio, json, sys, time, wave
import websockets
async def main(port):
    wf = wave.open('artifacts/voice-samples/中文测试-16k.wav', 'rb')
    pcm = wf.readframes(wf.getnframes())
    async with websockets.connect(f'ws://127.0.0.1:{port}', max_size=None) as ws:
        t0 = time.time(); first = None; fin = None
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
                fin = time.time()-t0; print(f"{port} first_partial={first:.2f}s final={fin:.2f}s text={j['text']}")
                return
asyncio.run(main(int(sys.argv[1])))
EOF
( cd "$ROOT" && .funasr-env/bin/python "$OUT/smoke-timing.py" 10095 | tee "$OUT/gpu-timing.txt" )
( cd "$ROOT" && .funasr-env/bin/python "$OUT/smoke-timing.py" 10096 | tee "$OUT/cpu-timing.txt" )

echo "== 3. 容器 f7（configtool + 两档核心场景）"
DEV_ARGS=()
for d in /dev/dri/renderD*; do
    [ -e "$d" ] && DEV_ARGS+=(--device "$d") && break
done
timeout 400 podman run --rm \
    --user 0 --userns=keep-id "${DEV_ARGS[@]}" \
    -v "$ROOT/scripts:/scripts:ro" \
    -v "$ROOT/artifacts/dist:/opt/dist:ro" \
    -v "$ROOT/artifacts/voice-samples:/samples:ro" \
    -v "$OUT:/out" \
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
cat "$OUT/f7-out.log" | grep -aE "^S[0-9]|✓|✗|F7 结果|耗时|全部通过|存在失败"
podman rm -fa >/dev/null 2>&1 || true

echo "== 4. 资源采样"
GPU_VRAM=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader 2>/dev/null | awk -v p="$GPU_PID" -F', ' '$1==p {print $2}')
[ -z "$GPU_VRAM" ] && GPU_VRAM="（未见 GPU 进程——采样时序问题）"
CPU_RSS=$(ps -o rss= -p "$CPU_PID" 2>/dev/null | awk '{printf "%dMB", $1/1024}')
echo "GPU(:10095) VRAM=$GPU_VRAM | CPU(:10096, int8) RSS=$CPU_RSS"
{
  echo "## F7 部署矩阵数据"
  echo "- GPU: $(cat "$OUT/gpu-timing.txt" 2>/dev/null) VRAM=$GPU_VRAM"
  echo "- CPU int8: $(cat "$OUT/cpu-timing.txt" 2>/dev/null) RSS=$CPU_RSS"
} > "$OUT/matrix.md"

echo "== 5. 收尾（停 CPU 实例，GPU 保留常驻）"
FUNASR_PORT=10096 bash "$ROOT/scripts/funasr-serve.sh" stop >/dev/null || true
echo "完成。数据：$OUT/matrix.md"
