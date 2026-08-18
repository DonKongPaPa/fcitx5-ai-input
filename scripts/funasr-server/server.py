#!/usr/bin/env python3
"""voiceinput 的 FunASR 流式识别服务（宿主原生运行，无容器）。

实验 001 结论的落地：Fun-ASR-MLT-Nano 没有 chunk 流式接口，"实时"用
累积窗口实现——每 WINDOW_MS 对从头累积的音频整体重识别，回传全量文本。
GPU（实验数据 RTF 0.07 / 首包 ~1s）下体验流畅；CPU 档可用但慢。

协议（面向 fcitx5 addon 的 C++ 手写 WS 客户端，刻意保持简单）：
  client → server : TEXT  {} （首帧配置，可省略，全部取默认）
                    BINARY s16le/16kHz/mono PCM 分片
                    TEXT  {"is_speaking": false} 结束
  server → client : TEXT  {"text": "全量累积文本", "is_final": false} 每窗口
                    TEXT  {"text": "最终文本",     "is_final": true}  结束后

单客户端串行推理（本地个人部署语义）；识别调用与实验 20_infer.py 完全一致。
"""
import argparse
import asyncio
import json
import logging
import os
import sys
import time

import numpy as np

logging.basicConfig(level=logging.INFO,
                    format='%(asctime)s [%(levelname)s] %(message)s')
log = logging.getLogger("funasr-serve")

WINDOW_MS = 720          # 累积窗口（官方 demo2 同款）
SAMPLE_RATE = 16000

raw_model = None
model_kwargs = {}


def load_model(model_dir: str, remote_code: str, device: str):
    """绕过 AutoModel.generate（新版对 ndarray 输入不再包 chat 模板），
    直接用 remote_code 的模型类（demo2 同款：张量输入 + prev_text 上下文）"""
    global raw_model, model_kwargs
    from funasr import AutoModel
    t0 = time.time()
    raw_model, model_kwargs = AutoModel.build_model(
        model=model_dir,
        trust_remote_code=True,
        remote_code=remote_code,
        device=device,
        disable_update=True,
    )
    logging.getLogger("funasr-serve")
    log.info("模型加载完成 %.1fs device=%s dir=%s", time.time() - t0,
             device, model_dir)


def extract_text(res) -> str:
    try:
        item = res[0][0]
        return item["text"] if isinstance(item, dict) else str(item)
    except Exception:
        return ""


def infer(pcm: np.ndarray, language: str) -> str:
    """pcm: float32 [-1,1] 单声道。

    实测结论（语音测试集验证）：prev_text 上下文会"锚死"早期文本——
    音频增长后模型不再补充新内容（demo2 优化在 MLT Nano 上适得其反），
    且早期短前缀的垃圾识别会毒化整条链。故每窗口全量重识别（不带
    prev），GPU 实测单窗 0.25-0.35s，720ms 节奏下流畅。"""
    import torch
    log.info("infer pcm=%s lang=%r", (pcm.dtype, pcm.shape), language)
    try:
        res = raw_model.inference(
            [torch.tensor(pcm)],
            prev_text="",
            language=language,
            itn=True,
            **model_kwargs,
        )
        return extract_text(res)
    except Exception:
        log.exception("inference failed")
        return ""


def trim_unstable_tail(text: str, keep_tokens: int = 3) -> str:
    """非最终轮截掉末尾 token（不稳定尾巴），并清理坏字节。
    中文 ~1字/token，3 比 demo2 的 5 温和（5 会剪掉小半句）"""
    tok = model_kwargs.get("tokenizer")
    if not tok or not text:
        return text
    try:
        ids = tok.encode(text)
        if len(ids) <= keep_tokens:
            return text
        return tok.decode(ids[:-keep_tokens]).replace("\ufffd", "")
    except Exception:
        return text


def s16_to_f32(raw: bytes) -> np.ndarray:
    a = np.frombuffer(raw, dtype="<i2").astype(np.float32)
    return a / 32768.0


def looks_like_silence_hallucination(text: str) -> bool:
    """静音段幻觉：同一片段连重复（"你那个，你那个，…"）或超短语气词"""
    if not text:
        return True
    t = text.rstrip("。，？！.?！， ")
    if len(t) <= 2:  # "嗯" "哦" 一类：静音常见产物（真实语音首窗可能极短，
        return len(t) <= 1 and len(text) <= 3  # 放过 "好。" 这类短真实语
    # 任意 2-6 字片段连续出现 ≥3 次
    for n in range(2, 7):
        seg = t[:n]
        if len(seg) == n and t.count(seg) >= 3 and len(seg) * 3 >= len(t) - 2:
            return True
    return False


async def handle(conn):
    peer = conn.remote_address
    log.info("client connected %s", peer)
    pcm_all = bytearray()
    last_infer_samples = 0
    window_samples = SAMPLE_RATE * WINDOW_MS // 1000
    language = "中文"  # 首帧可覆盖：{"language": "英文"}
    try:
        async for msg in conn:
            if isinstance(msg, str):
                try:
                    j = json.loads(msg)
                except ValueError:
                    continue
                if j.get("language"):
                    language = j["language"]
                    continue
                if j.get("is_speaking") is False:
                    break
                continue
            pcm_all.extend(msg)
            # 新增音频超过一个窗口才重识别；积压超过 3s 时跳过中间窗
            #（推理比音频慢时防止 partial 追赶链拖死 final）
            backlog_s = (len(pcm_all) - last_infer_samples) / 2 / SAMPLE_RATE
            if backlog_s >= 3.0:
                last_infer_samples = len(pcm_all)
                continue
            if len(pcm_all) - last_infer_samples >= window_samples * 2:
                t0 = time.time()
                text = infer(s16_to_f32(bytes(pcm_all)), language)
                last_infer_samples = len(pcm_all)
                shown = trim_unstable_tail(text)
                if shown and not looks_like_silence_hallucination(shown):
                    await conn.send(json.dumps(
                        {"text": shown, "is_final": False},
                        ensure_ascii=False))
                else:
                    shown = ""  # 幻觉/空：不下发
                log.info("partial %.1fs audio, infer %.2fs: %s",
                         len(pcm_all) / 2 / SAMPLE_RATE,
                         time.time() - t0, shown[:50])
    except Exception:
        log.exception("connection error")
    # 最终：全量重识别一次（不剪尾，含最后不足一窗的尾巴）
    t0 = time.time()
    text = infer(s16_to_f32(bytes(pcm_all)), language) \
        if pcm_all else ""
    log.info("final %.1fs audio, infer %.2fs: %s",
             len(pcm_all) / 2 / SAMPLE_RATE, time.time() - t0, text[:80])
    try:
        await conn.send(json.dumps({"text": text, "is_final": True},
                                   ensure_ascii=False))
    except Exception:
        pass
    log.info("client done %s", peer)


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=10095)
    ap.add_argument("--device", default=None)
    ap.add_argument("--model-dir", default=os.environ.get("MODEL_DIR", ""))
    ap.add_argument("--remote-code", default="")
    args = ap.parse_args()

    device = args.device or ("cuda:0" if os.path.exists("/dev/nvidia0")
                             else "cpu")
    load_model(args.model_dir, args.remote_code, device)

    import websockets
    # 单连接串行：本地个人部署，识别互相排队而不是并发打爆显存
    sem = asyncio.Semaphore(1)

    async def guarded(conn):
        async with sem:
            await handle(conn)

    async with websockets.serve(guarded, args.host, args.port,
                                max_size=None):
        log.info("listening on %s:%d device=%s", args.host, args.port, device)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
