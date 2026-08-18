#!/usr/bin/env bash
# 容器内音频采集链路冒烟：pipewire + 虚拟麦 + parec
set -u
export XDG_RUNTIME_DIR=/run/user/1000
LOG_DIR=/tmp/logs
mkdir -p "$LOG_DIR"
source /scripts/env/common.sh >/dev/null 2>&1 || true

start_audio >/dev/null 2>&1
setup_virtual_mic >/dev/null 2>&1
echo "工具: $(which parec pw-play 2>/dev/null | tr '\n' ' ')"

pw-play --target vi_mic /samples/中文测试-16k.wav >/dev/null 2>&1 &
sleep 0.3
timeout 3 parec --format=s16le --rate=16000 --channels=1 > /tmp/cap.raw 2>/tmp/parec.log || true
python3 -c "
import array
d = open('/tmp/cap.raw','rb').read()
a = array.array('h'); a.frombytes(d[:len(d)//2*2])
peak = max((abs(x) for x in a), default=0)
print(f'采集 {len(d)} 字节 ≈ {len(d)/32000:.2f}s, 峰值 {peak}（>1000 即有声音）')"
tail -2 /tmp/parec.log 2>/dev/null
