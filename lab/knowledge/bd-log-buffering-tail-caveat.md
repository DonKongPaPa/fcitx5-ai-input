---
id: bd-log-buffering-tail-caveat
category: build-deploy
title: fcitx5 stderr 重定向到文件是块缓冲
---

# fcitx5 stderr 重定向到文件是块缓冲

- **症状**：journal/日志滞后，时间线推断被误导
- **根因**：stdio 全缓冲
- **约束规则**：以事件相对顺序+水位行号对账，勿信赖秒级时序；紧急时 SIGUSR?/重启冲刷
- **来源**：c7 卡死调查弯路
- **验证**：-
