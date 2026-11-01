#!/usr/bin/env python3
# card-qml feeder：Unix socket 服务端，按行回放 lab/spec/events/*.jsonl 到
# Quickshell 卡片（card-qml/shell.qml）。wire 约定（lab/spec/protocol.md §2/§8）：
# 每行紧凑 JSON + \n；_delay_ms=分发前等待毫秒；_comment 行跳过；seq 重编全局
# 单调（接收方不依赖 seq）。文件不存在则回放内置最小样例集（按 events.schema.json
# 造，proto_check.py 可校验）；--write-samples 可把样例集落盘。
import argparse
import json
import os
import socket
import sys
import threading
import time

CONNECT_TIMEOUT = 60.0
TAIL_WAIT = 3.0  # 回放结束后留窗等晚到的回写（ready/resize/select/...）


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# 内置最小样例集：ui 通道 out 方向各事件至少出现一次的最短走查（不含 dir=in，
# 选择交互由真人在卡片上点击产生）。顺序满足 proto_check.py 不变量：
# hello 首条、voice/idle 收尾。
BUILTIN_FLOWS = {
    "voice": [
        {"v": 1, "channel": "ui", "dir": "out", "method": "hello",
         "args": {"proto": 1, "caps": ["paging", "preedit"]}},
        {"v": 1, "channel": "ui", "dir": "out", "method": "theme",
         "args": {"font_size": 16, "anim": 1.6}},
        {"v": 1, "channel": "ui", "dir": "out", "method": "voice/recording",
         "args": {"partial": "你好", "elapsed_ms": 800}, "_delay_ms": 300},
        {"v": 1, "channel": "ui", "dir": "out", "method": "voice/recording",
         "args": {"partial": "你好这是语音", "elapsed_ms": 2000},
         "_delay_ms": 400},
        {"v": 1, "channel": "ui", "dir": "out", "method": "voice/candidates",
         "args": {"final": "你好，这是语音输入。",
                  "candidates": ["你好，这是语音输入。", "你好这是语音输入"],
                  "hover": -1, "llm_dummy": True}, "_delay_ms": 400},
        {"v": 1, "channel": "ui", "dir": "out", "method": "voice/idle",
         "args": {}, "_delay_ms": 1500},
    ],
    "panel": [
        {"v": 1, "channel": "ui", "dir": "out", "method": "hello",
         "args": {"proto": 1, "caps": ["paging", "preedit", "vertical"]}},
        {"v": 1, "channel": "ui", "dir": "out", "method": "theme",
         "args": {"font_size": 16, "anim": 1.0}},
        {"v": 1, "channel": "ui", "dir": "out", "method": "panel/update",
         "args": {"preedit": [{"text": "nihao", "underline": True}],
                  "aux_up": "拼音",
                  "candidates": [{"label": "1.", "text": "你好",
                                  "comment": "nǐ hǎo"},
                                 {"label": "2.", "text": "你号"},
                                 {"label": "3.", "text": "泥嚎"}],
                  "cursor": 0, "layout": "horizontal",
                  "has_prev": False, "has_next": True, "page": 0,
                  "im_name": "pinyin"}, "_delay_ms": 300},
        {"v": 1, "channel": "ui", "dir": "out", "method": "panel/update",
         "args": {"preedit": [{"text": "shuju", "underline": True}],
                  "candidates": [{"label": "1.", "text": "数据"},
                                 {"label": "2.", "text": "输据"},
                                 {"label": "3.", "text": "书局"},
                                 {"label": "4.", "text": "束句"},
                                 {"label": "5.", "text": "薯菊"}],
                  "cursor": 1, "layout": "vertical",
                  "has_prev": False, "has_next": False, "page": 0,
                  "im_name": "pinyin"}, "_delay_ms": 500},
        {"v": 1, "channel": "ui", "dir": "out", "method": "panel/hide",
         "args": {}, "_delay_ms": 400},
    ],
}


def load_flow(path):
    """文件存在→逐行解析；不存在→内置样例集（文件名含 panel 选 panel 流）。"""
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return [json.loads(line) for line in f if line.strip()]
    kind = "panel" if "panel" in os.path.basename(path) else "voice"
    log(f"MISSING {path} → 回放内置最小样例集 {kind}")
    return BUILTIN_FLOWS[kind]


def write_samples(directory):
    os.makedirs(directory, exist_ok=True)
    for kind, flow in BUILTIN_FLOWS.items():
        out = os.path.join(directory, kind + ".jsonl")
        with open(out, "w", encoding="utf-8") as f:
            for env in flow:
                f.write(json.dumps(env, ensure_ascii=False,
                                   separators=(",", ":")) + "\n")
        log(f"WROTE {out}")


def main():
    ap = argparse.ArgumentParser(
        description="card-qml 回放 feeder（Unix socket 服务端，卡片为客户端）")
    ap.add_argument("-s", "--sock", default=os.path.join(
        os.environ.get("XDG_RUNTIME_DIR", "/run/user/1000"),
        "aiinput-card.sock"), help="socket 路径（默认 $XDG_RUNTIME_DIR/"
        "aiinput-card.sock，与 shell.qml 的 AIINPUT_CARD_SOCK 对应）")
    ap.add_argument("--write-samples", metavar="DIR",
                    help="把内置最小样例集写成 DIR/voice.jsonl、DIR/panel.jsonl"
                         " 后退出")
    ap.add_argument("files", nargs="*",
                    help="lab/spec/events/*.jsonl（不存在则回放内置样例集）")
    args = ap.parse_args()

    if args.write_samples:
        write_samples(args.write_samples)
        return 0
    if not args.files:
        ap.error("至少给一个 jsonl 文件（或 --write-samples）")

    sock_path = args.sock
    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    srv.listen(1)
    srv.settimeout(CONNECT_TIMEOUT)
    log(f"LISTEN {sock_path}（等待 quickshell 卡片连接，超时 {CONNECT_TIMEOUT:.0f}s）")
    try:
        conn, _ = srv.accept()
    except socket.timeout:
        log("FAIL no-connection：quickshell 未在时限内连接（feeder 须先起）")
        return 3
    log("ACCEPT card connected")
    srv.close()  # 已建立连接，停止接收新连接

    def reader(c):
        buf = b""
        while True:
            try:
                chunk = c.recv(4096)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if line.strip():
                    log(f"RECV-IN {line.decode('utf-8', 'replace')}")

    threading.Thread(target=reader, args=(conn,), daemon=True).start()

    wire_seq = 0
    sent = 0
    for path in args.files:
        log(f"REPLAY {path}")
        for env in load_flow(path):
            if "_comment" in env:
                continue
            delay = env.get("_delay_ms", 0)
            if delay:
                time.sleep(delay / 1000.0)
            wire_seq += 1
            env = dict(env)
            env["seq"] = wire_seq
            env.pop("_delay_ms", None)  # 控制行字段不进 wire（协议 §2 无此键）
            wire = json.dumps(env, ensure_ascii=False, separators=(",", ":"))
            conn.sendall((wire + "\n").encode("utf-8"))
            sent += 1
            log(f"SENT seq={wire_seq} method={env.get('method')} "
                f"dir={env.get('dir')}")
    time.sleep(TAIL_WAIT)
    conn.close()
    try:
        os.unlink(sock_path)
    except OSError:
        pass
    log(f"DONE sent={sent}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
