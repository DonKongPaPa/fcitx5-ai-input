#!/usr/bin/env python3
# qml-probe feeder：Unix socket 服务端，按行回放 lab/spec/events/*.jsonl。
# wire 约定（lab/spec/protocol.md §2/§8）：每行紧凑 JSON + \n；_delay_ms=分发前
# 等待毫秒；_comment 行跳过；同时接收卡片 ui→addon（dir=in）回写并打日志。
import json
import os
import socket
import sys
import threading
import time

CONNECT_TIMEOUT = 60.0
TAIL_WAIT = 4.0  # 回放结束后留窗等晚到的回写（select/ready）


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def main():
    if len(sys.argv) < 3:
        print("usage: feeder.py SOCK_PATH JSONL [JSONL...]", file=sys.stderr)
        return 2
    sock_path, files = sys.argv[1], sys.argv[2:]

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
        log("FAIL no-connection：quickshell 未在时限内连接")
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

    sent_out = sent_in = 0
    wire_seq = 0  # 回放文件各自 seq 从 1 起；线上重编为全局单调（协议 §2：接收方不依赖 seq）
    for path in files:
        log(f"REPLAY {path}")
        with open(path, encoding="utf-8") as f:
            for raw in f:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    env = json.loads(raw)
                except json.JSONDecodeError:
                    log(f"SKIP non-json: {raw[:60]}")
                    continue
                if "_comment" in env:
                    continue
                delay = env.get("_delay_ms", 0)
                if delay:
                    time.sleep(delay / 1000.0)
                wire_seq += 1
                env["seq"] = wire_seq
                wire = json.dumps(env, ensure_ascii=False, separators=(",", ":"))
                conn.sendall((wire + "\n").encode("utf-8"))
                if env.get("dir") == "in":
                    sent_in += 1
                else:
                    sent_out += 1
                log(f"SENT seq={env.get('seq')} method={env.get('method')} dir={env.get('dir')}")

    time.sleep(TAIL_WAIT)
    conn.close()
    try:
        os.unlink(sock_path)
    except OSError:
        pass
    log(f"DONE sent_out={sent_out} sent_in={sent_in}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
