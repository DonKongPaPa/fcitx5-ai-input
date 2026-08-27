#!/usr/bin/env bash
# proto-test 容器（快档）：协议 v1 对拍——schema 结构+事件参数+跨通道
# 不变量，秒级。镜像复用 aiinput-base（纯标准库，零依赖）。
# 两段：①回放脚本静态对拍 ②后端实拍（驱动真实 stdio 子进程，产物过
# 同一校验器——后端是协议一等公民，输出漂移当场红）。
# 触发：改 lab/spec/ 或 backends/ 后。用法：make proto-test
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="localhost/aiinput-base:latest"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/artifacts/prototest/$RUN_ID"
mkdir -p "$OUT"

podman image exists "$IMAGE" || { echo "!! 先 make image-base"; exit 1; }
podman run --rm --userns=keep-id \
    -v "$ROOT/lab:/lab:ro" \
    -v "$ROOT/backends:/backends:ro" \
    -v "$OUT:/out" \
    localhost/aiinput-base:latest \
    bash -c '
set -e
python3 /lab/spec/proto_check.py --out /out/proto-report.json /lab/spec/events

# —— 后端实拍：真实子进程跑一轮会话，stdout 落盘再对拍 ——
mkdir -p /tmp/be && cd /tmp/be
python3 - <<PYEOF
import json, os, pathlib, subprocess, time

def env():
    return dict(os.environ, AIINPUT_DUMMY_TEXT="我们出去玩吧",
                AIINPUT_DUMMY_INTERVAL="0.05")

def line(method, args):
    return json.dumps({"v": 1, "channel": "x", "dir": "out",
                       "method": method, "args": args},
                      ensure_ascii=False) + "\n"

# asr：hello → start（等 2 个 partial tick）→ stop（final+退出）
p = subprocess.Popen(["python3", "/backends/asr-dummy.py"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     text=True, env=env())
p.stdin.write(line("hello", {"proto": 1, "caps": []})); p.stdin.flush()
time.sleep(0.1)
p.stdin.write(line("asr/start", {"cfg": {}, "streaming": True})); p.stdin.flush()
time.sleep(0.15)
p.stdin.write(line("asr/stop", {})); p.stdin.flush()
out, _ = p.communicate(timeout=10)
assert p.returncode == 0, f"asr 后端退出码 {p.returncode}"
assert "asr/partial" in out, "asr 实拍缺 partial（流式未触发？）"
assert "asr/final" in out, "asr 实拍缺 final"
pathlib.Path("asr-backend.jsonl").write_text(out)

# refine：hello → request（result+退出）
r = subprocess.run(["python3", "/backends/refine-dummy.py"],
                   input=line("hello", {"proto": 1, "caps": []}) +
                         line("refine/request", {"raw": "我们出去玩吧",
                                                 "mode": "candidates"}),
                   capture_output=True, text=True, timeout=10)
assert r.returncode == 0, f"refine 后端退出码 {r.returncode}"
assert "refine/result" in r.stdout, "refine 实拍缺 result"
pathlib.Path("refine-backend.jsonl").write_text(r.stdout)
PYEOF
python3 /lab/spec/proto_check.py --out /out/backend-report.json /tmp/be
cp /tmp/be/*.jsonl /out/
'
echo ">> proto-test 完成：$OUT/proto-report.json + backend-report.json"
