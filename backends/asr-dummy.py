#!/usr/bin/env python3
"""asr-dummy：v1 协议 stdio ASR 后端（P6 解耦试验田的参照实现）。

契约见 lab/spec/protocol.md asr 通道事件表：
  stdin  ← dir:"out"（hello / asr/start / asr/stop / asr/cancel）
  stdout → dir:"in" （hello / asr/partial* / asr/final / asr/cancelled）

无音频——模拟流式：asr/start 后逐字吐 partial（AIINPUT_DUMMY_TEXT，
默认「我们出去玩吧」），asr/stop 回全文 final。真实 ASR 后端照此骨架
换掉 partial/final 的生成源即可（envelope 编解码不用动）。
"""
import json
import os
import sys
import threading


def emit(method, args, seq=[0]):
    seq[0] += 1
    envelope = {
        "v": 1, "channel": "asr", "dir": "in",
        "method": method, "seq": seq[0], "args": args,
    }
    # separators 压缩：wire 上不得有冒号后空格（对拍器/解析器的紧凑约定）
    line = json.dumps(envelope, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def iter_chars(text):
    """逐字（码点）推进，模拟流式中间结果的全量式推送"""
    chars = list(text)
    for i in range(1, len(chars) + 1):
        yield "".join(chars[:i])


class Session:
    def __init__(self):
        self.text = os.environ.get("AIINPUT_DUMMY_TEXT", "我们出去玩吧")
        self.interval = float(os.environ.get("AIINPUT_DUMMY_INTERVAL", "0.4"))
        self.pos = 0
        self.timer = None
        self.lock = threading.Lock()

    def start(self, streaming):
        with self.lock:
            self.pos = 0
        if streaming:
            self.schedule_next()

    def schedule_next(self):
        self.timer = threading.Timer(self.interval, self.tick)
        self.timer.daemon = True
        self.timer.start()

    def tick(self):
        with self.lock:
            if self.pos >= len(self.text):
                return  # 等 asr/stop 收尾
            self.pos += 1
            partial = self.text[: self.pos]
        emit("asr/partial", {"text": partial})
        self.schedule_next()

    def stop(self):
        if self.timer:
            self.timer.cancel()
        emit("asr/final", {"text": self.text})


def main():
    session = Session()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            envelope = json.loads(line)
        except json.JSONDecodeError:
            continue
        method = envelope.get("method", "")
        if method == "hello":
            emit("hello", {"proto": 1, "caps": ["streaming"]})
        elif method == "asr/start":
            session.start(envelope.get("args", {}).get("streaming", True))
        elif method == "asr/stop":
            session.stop()
            return
        elif method == "asr/cancel":
            emit("asr/cancelled", {})
            return
        # 未知 method 忽略（向前兼容）


if __name__ == "__main__":
    main()
