#!/usr/bin/env python3
# qml-probe 断言：读容器内日志，判 layer map / envelope 收发 / margins 即时性。
# 用法：python3 -I assert-results.py OUT_DIR LOG_DIR
import json
import os
import re
import sys

out_dir, log_dir = sys.argv[1], sys.argv[2]

EXPECTED_OUT_H = 1080  # sway-config 里 HEADLESS-1 的高度，scale 1.0


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


qs = read(os.path.join(log_dir, "quickshell.log"))
feeder = read(os.path.join(log_dir, "feeder.log"))
niri_layers = read(os.path.join(log_dir, "niri-layers.txt"))
niri_msg_err = read(os.path.join(log_dir, "niri-msg-err.txt"))

results = []


def check(name, status, detail):
    results.append((name, status, detail))  # status: PASS / FAIL / SKIP


def parse_recv_in(text):
    """feeder 的 RECV-IN 行（带 [HH:MM:SS] 时间戳前缀）是卡片 write 回的原始 wire JSON。"""
    out = []
    for line in text.splitlines():
        if "RECV-IN " not in line:
            continue
        payload = line.split("RECV-IN ", 1)[1].strip()
        try:
            out.append(json.loads(payload))
        except Exception:
            pass
    return out


# A1. layer map（quickshell 视角：MAP_OK 意味着 compositor 已 configure 并 commit）
m = re.search(r"QS_PROBE: MAP_OK .*width=(\d+) height=(\d+)", qs)
check("A1 layer surface map（quickshell MAP_OK：compositor configure 后 w/h>0）",
      "PASS" if m else "FAIL",
      m.group(0) if m else "quickshell.log 无 QS_PROBE: MAP_OK")

# A2. layer map（niri 视角：niri msg layers 列出 aiinput-probe）
if "aiinput-probe" in niri_layers:
    check("A2 niri msg layers 列出 namespace=aiinput-probe", "PASS",
          "niri-layers.txt 含 aiinput-probe")
elif niri_layers.strip() == "":
    check("A2 niri msg layers 列出 namespace=aiinput-probe", "SKIP",
          (niri_msg_err or "niri msg 不可用/无输出").strip()[:160])
else:
    check("A2 niri msg layers 列出 namespace=aiinput-probe", "FAIL",
          "layers 列表存在但未含 aiinput-probe：" + niri_layers[:160].replace("\n", " | "))

# B1. envelope 全量收到：feeder SENT(dir=out) 的 (seq, method) 序列 == 卡片 ENV 序列
# （feeder 已把线上 seq 重编为全局单调，两侧序列可精确对拍）
sent = re.findall(r"SENT seq=(\S+) method=(\S+) dir=out", feeder)
got = re.findall(r"QS_PROBE: ENV seq=(\S+) method=(\S+)", qs)
check("B1 envelope 全量收到（SENT(dir=out) ≡ 卡片 ENV，逐条对拍）",
      "PASS" if sent and sent == got else "FAIL",
      f"sent={len(sent)} got={len(got)} "
      f"first_diff={next((i for i, (a, b) in enumerate(zip(sent, got)) if a != b), None)}")

# B2. dir=in 行被 UI 忽略（协议 §8：ui 侧分发器只消费 dir=out）
ignored_in = re.findall(r"QS_PROBE: IGNORED .*dir=in", qs)
check("B2 dir=in 行被卡片忽略（协议 §8）",
      "PASS" if ignored_in else "FAIL", f"IGNORED dir=in 计数={len(ignored_in)}")

# C. ui→addon 方向：卡片经同一 socket write 回的 envelope 到达 feeder
recv_in = parse_recv_in(feeder)
got_ready = [e for e in recv_in if e.get("method") == "ready"]
got_select = [e for e in recv_in if e.get("method") == "select"]
check("C1 卡片回写 ready+select 到达 feeder（Socket.write/flush 方向）",
      "PASS" if got_ready and got_select else "FAIL",
      f"RECV-IN 共 {len(recv_in)} 条：ready={len(got_ready)} select={len(got_select)}")

# D. margins 改动即时生效（map 后原地改 margins.top，未做任何重 map 动作）。
#    判据：Δh == -Δtop（top+bottom 双锚下 height 随 margin 线性联动，同帧内完成）；
#    绝对高度不硬编码——嵌套 niri 的实际逻辑输出高会被外层 sway 窗口边框
#    压缩（实测 1080 模式 → 1050 逻辑高），以 h0+t0+bottom 反推基准并记录
before = re.search(r"QS_PROBE: MARGIN_BEFORE height=(\d+) top=(\d+)", qs)
after = re.search(r"QS_PROBE: MARGIN_AFTER height=(\d+) top=(\d+)", qs)
BOTTOM_MARGIN = 10
if before and after:
    h0, t0 = int(before.group(1)), int(before.group(2))
    h1, t1 = int(after.group(1)), int(after.group(2))
    dh, dt = h1 - h0, t1 - t0
    base = h0 + t0 + BOTTOM_MARGIN  # 反推的有效输出逻辑高
    ok = dh == -dt and dt != 0
    check("D1 margins 改动即时生效（map 后原地改，Δh=-Δtop，未重 map）",
          "PASS" if ok else "FAIL",
          f"before h={h0},top={t0} → after h={h1},top={t1}；Δh={dh}，Δtop={dt}；"
          f"反推有效输出高={base}（niri 基准 {EXPECTED_OUT_H}，差值=外层 sway 窗口边框）")
else:
    check("D1 margins 改动即时生效（map 后原地改，Δh=-Δtop，未重 map）", "FAIL",
          "缺 QS_PROBE: MARGIN_BEFORE/MARGIN_AFTER 日志")

# 汇总
fails = [r for r in results if r[1] == "FAIL"]
skips = [r for r in results if r[1] == "SKIP"]
overall = "PASS" if not fails else "FAIL"
lines = ["== qml-probe 断言汇总 =="]
for name, status, detail in results:
    lines.append(f"[{status}] {name}\n       {detail}")
lines.append(f"RESULT: {overall}  (通过 {sum(1 for r in results if r[1]=='PASS')}"
             f"/{len(results)}，跳过 {len(skips)})")
summary = "\n".join(lines)
print(summary)

with open(os.path.join(out_dir, "summary.txt"), "w", encoding="utf-8") as f:
    f.write(summary + "\n")

sys.exit(0 if not fails else 1)
