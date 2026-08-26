#!/usr/bin/env python3
"""refine-dummy：v1 协议 stdio refine 后端（P6 解耦试验田的参照实现）。

契约见 lab/spec/protocol.md refine 通道事件表：
  stdin  ← dir:"out"（hello / refine/request）
  stdout → dir:"in" （hello / refine/result{candidates, engine_tag}）

规则占位（与 addon 内置 Dummy LLM 同语义）：候选 = [润色版, 原始版]，
润色 = 句末无标点则补「。」。真实 LLM 后端换掉 compute() 即可。
"""
import json
import sys

ENDING_PUNCT = "。！？！？.?!,，；;"


def polish(text):
    text = text.strip()
    if not text:
        return text
    if text[-1] not in ENDING_PUNCT:
        text += "。"
    return text


def emit(method, args, seq=[0]):
    seq[0] += 1
    envelope = {
        "v": 1, "channel": "refine", "dir": "in",
        "method": method, "seq": seq[0], "args": args,
    }
    # separators 压缩：wire 上不得有冒号后空格（对拍器/解析器的紧凑约定）
    line = json.dumps(envelope, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def compute(raw, mode):
    if mode == "polish":
        return [polish(raw)]
    return [polish(raw), raw]


def main():
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
            emit("hello", {"proto": 1, "caps": []})
        elif method == "refine/request":
            args = envelope.get("args", {})
            cands = compute(args.get("raw", ""), args.get("mode", "candidates"))
            emit("refine/result",
                 {"candidates": cands, "engine_tag": "dummy"})
            return
        # 未知 method 忽略（向前兼容）


if __name__ == "__main__":
    main()
