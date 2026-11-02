#!/usr/bin/env python3
"""aiinput-card-host 离屏渲染冒烟（frame-relay.md §5 T1 前置）。

假扮 SocketUi：控制 socket 收 ready 行、发 envelope；帧 socket 收 FRM 帧。
不依赖 niri/wayland——QT_QPA_PLATFORM=offscreen 下整条「envelope→渲染→帧」
链路在进程内闭环。最后一帧 BGRA 转 PNG 存盘供目检。

用法：python3 smoke_host.py [--sock /tmp/aiinput-smoke.sock] [--out /tmp/out]
"""
import argparse
import json
import os
import socket
import struct
import sys
import threading
import time

ap = argparse.ArgumentParser()
ap.add_argument("--sock", default="/tmp/aiinput-smoke.sock")
ap.add_argument("--out", default="/tmp/aiinput-smoke-out")
args = ap.parse_args()

frame_path = args.sock + "-frame"
for p in (args.sock, frame_path):
    try:
        os.unlink(p)
    except FileNotFoundError:
        pass

got = {"ready": None, "frames": [], "lines": []}
stop = threading.Event()


def serve(path, on_conn):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    # '/' 开头 = filesystem 路径；否则 abstract 名（与 SocketUi listenUnix
    # 同约定——容器 flow 里 filesystem socket 的 dentry 会被外部摘除）
    if not path.startswith("/"):
        path = "\0" + path
    s.bind(path)
    s.listen(2)
    s.settimeout(0.5)
    while not stop.is_set():
        try:
            c, _ = s.accept()
        except socket.timeout:
            continue
        on_conn(c)


ctrl_sock = [None]  # 已 accept 的控制连接（单客户端语义，后续 send 复用）


def control_conn(c):
    ctrl_sock[0] = c
    buf = b""
    c.settimeout(0.5)
    while not stop.is_set():
        try:
            chunk = c.recv(4096)
        except socket.timeout:
            continue
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if line.strip():
                got["lines"].append(line.decode())
                if b'"ready"' in line:
                    got["ready"] = line.decode()


def frame_conn(c):
    buf = b""
    c.settimeout(0.5)
    while not stop.is_set():
        try:
            chunk = c.recv(1 << 16)
        except socket.timeout:
            continue
        if not chunk:
            break
        buf += chunk
        while len(buf) >= 16 and buf[:3] == b"FRM":
            w, h, size = struct.unpack("<III", buf[3:15])
            if buf[15:16] != b"\n":
                print("BADHDR", buf[:16])
                return
            if len(buf) < 16 + size:
                break
            payload = buf[16:16 + size]
            buf = buf[16 + size:]
            got["frames"].append((w, h, payload))


t1 = threading.Thread(target=serve, args=(args.sock, control_conn), daemon=True)
t2 = threading.Thread(target=serve, args=(frame_path, frame_conn), daemon=True)
t1.start()
t2.start()

env = os.environ.copy()
env["AIINPUT_CARD_SOCK"] = args.sock
env.pop("AIINPUT_HOST_RENDER", None)
import subprocess
import shutil
qml_src = "/work/card-qml"
host_bin = "/usr/lib/fcitx5/aiinput-card-host"
if os.path.exists(host_bin):
    # 宿主本地复测：安装版二进制 + 安装版 QML
    qml_src = "/usr/share/fcitx5-aiinput/card-qml"
host = subprocess.Popen(
    [host_bin if os.path.exists(host_bin) else "/work/artifacts/dist/lib/fcitx5/aiinput-card-host",
     "--qml-dir", qml_src],
    env=env, stderr=subprocess.PIPE)
try:
    # 等 ready（控制通道连通 + 场景装载完成的信号）
    for _ in range(100):
        if got["ready"]:
            break
        time.sleep(0.1)
    print("READY:", got["ready"])

    themed = [False]

    def send(method, a):
        if method != "ready" and not themed[0]:
            themed[0] = True
            send("theme", {"font_path": "/usr/share/fonts/TTF/MiSans VF.ttf",
                           "font_family": "MiSans VF", "font_size": 12,
                           "anim": 1.0, "scale": 1.0})
            time.sleep(0.5)
        line = json.dumps({"v": 1, "channel": "ui", "dir": "out",
                           "method": method, "seq": 1, "args": a})
        ctrl_sock[0].sendall((line + "\n").encode())

    send("hello", {"caps": ["paging"]})
    send("panel/update", {
        "preedit": [{"text": "nihaos", "underline": True},
                    {"text": "hi", "underline": False}],
        "aux_up": "", "aux_down": "nihao",
        "candidates": [
            {"label": "1", "text": "你好"},
            {"label": "2", "text": "你号"},
            {"label": "3", "text": "拟好"},
            {"label": "4", "text": "泥壕"},
            {"label": "5", "text": "妮好"}],
        "cursor": 0, "layout": "horizontal",
        "has_prev": False, "has_next": True, "page": 0,
        "im_name": "rime"})
    time.sleep(1.5)
    send("panel/update", {
        "preedit": [{"text": "nihaoshijie", "underline": True}],
        "aux_up": "", "aux_down": "",
        "candidates": [
            {"label": "1", "text": "你好世界"},
            {"label": "2", "text": "你号世界"}],
        "cursor": 0, "layout": "vertical",
        "has_prev": False, "has_next": False, "page": 0,
        "im_name": "rime"})
    for i in range(8):
        send("panel/update", {
            "preedit": [{"text": "ni hao", "underline": False}],
            "aux_up": "", "aux_down": "",
            "candidates": [{"label": "1 ", "text": "你好"},
                           {"label": "2 ", "text": "拟好"},
                           {"label": "3 ", "text": "你"},
                           {"label": "4 ", "text": "尼"},
                           {"label": "5 ", "text": "逆"}],
            "cursor": 0, "layout": "horizontal",
            "has_prev": False, "has_next": True, "page": 0, "im_name": "rime"})
        time.sleep(0.4)
    time.sleep(1.5)
    # 超长 preedit（通配输入 份额×N 实测反馈）：宽度须封顶 640 折行
    send("panel/update", {
        "preedit": [{"text": "份额" * 40, "underline": True}],
        "aux_up": "", "aux_down": "",
        "candidates": [{"label": str(i + 1), "text": "份额" * 8}
                       for i in range(5)],
        "cursor": 0, "layout": "horizontal",
        "has_prev": False, "has_next": True, "page": 0, "im_name": "rime"})
    time.sleep(1.5)
    # 宿主精确数据复现（label 尾空格；rime hint 布局）
    send("hello", {"caps": []})
    send("panel/update", {
        "preedit": [],
        "aux_up": "", "aux_down": "",
        "candidates": [{"label": "1 ", "text": "候选"},
                       {"label": "2 ", "text": "后续"},
                       {"label": "3 ", "text": "后序"},
                       {"label": "4 ", "text": "后"},
                       {"label": "5 ", "text": "候"}],
        "cursor": 0, "layout": "horizontal",
        "has_prev": False, "has_next": True, "page": 0, "im_name": "rime"})
    time.sleep(1.5)
finally:
    rc = host.poll()
    if rc is None:
        host.terminate()
        try:
            _, err = host.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            host.kill()
            _, err = host.communicate()
    else:
        err = None
    stop.set()
    t1.join(timeout=2)
    t2.join(timeout=2)

print("FRAMES:", len(got["frames"]))
if got["frames"]:
    w, h, payload = got["frames"][-1]
    print("LAST:", w, "x", h, len(payload), "B", "expect", w * h * 4)
    os.makedirs(args.out, exist_ok=True)
    # BGRA 预乘 → RGB PPM（忽略 alpha 供目检）+ 原始 BGRA 存档
    rgb = bytearray(w * h * 3)
    for px in range(w * h):
        rgb[px * 3] = payload[px * 4 + 2]
        rgb[px * 3 + 1] = payload[px * 4 + 1]
        rgb[px * 3 + 2] = payload[px * 4]
    with open(os.path.join(args.out, "smoke-frame.ppm"), "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (w, h) + bytes(rgb))
    print("PPM:", os.path.join(args.out, "smoke-frame.ppm"))
print("CTRL LINES:", got["lines"][:5])
if err:
    print("HOST STDERR (tail):")
    tail = err.decode(errors="replace").splitlines()
    for l in tail[-25:]:
        print("  ", l)
sys.exit(0 if got["frames"] else 1)
