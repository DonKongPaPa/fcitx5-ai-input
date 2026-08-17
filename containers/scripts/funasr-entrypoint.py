#!/usr/bin/env python3
"""FunASR WebSocket 服务入口（占位）。

M1 阶段仅验证依赖可用；M3+ 接入真实引擎时替换为完整流式服务
（AutoModel paraformer-zh 2pass + websocket server，模型从 ModelScope 拉取）。
"""
import asyncio
import json

from funasr import AutoModel


async def main() -> None:
    print("加载 FunASR 模型（首次运行从 ModelScope 下载）……", flush=True)
    model = AutoModel(model="paraformer-zh")
    print("模型就绪", flush=True)
    # 占位：保持运行，等待 M3+ 实现完整的 wss 服务
    while True:
        await asyncio.sleep(3600)


if __name__ == "__main__":
    asyncio.run(main())
