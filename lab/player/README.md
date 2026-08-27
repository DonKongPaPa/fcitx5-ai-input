# 试验田：UI 回放宿主（dummy 驱动）

不依赖 C++ 对端，宿主机直接演示/调试 UI（产品 UI 代码不复制，同一份
flutter/lib）：

```bash
# 语音全状态流（录音流式→候选→选择→idle）
UI_TRANSPORT=mock UI_REPLAY=../lab/spec/events/voice-full.jsonl flutter run -d linux

# 拼音面板数据形状（P4 前的视觉预演——panel/* 当前被 UI 忽略）
UI_TRANSPORT=mock UI_REPLAY=../lab/spec/events/pinyin-flow.jsonl flutter run -d linux
```

- UI 发出的命令（ready/resize/selectCandidate/...）由 MockHost 打印
  （`[mock-ui] -> method args`）
- 协议定义：lab/spec/protocol.md；回放格式：每行一个 envelope，支持
  `_delay_ms`（分发前等待）与 `_comment`
- 自动化跑法（容器、golden 基线）：`make ui-test`
