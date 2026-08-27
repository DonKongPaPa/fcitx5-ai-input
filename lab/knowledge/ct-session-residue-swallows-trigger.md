---
id: ct-session-residue-swallows-trigger
category: container-test
title: 候选/录音残留吞下一用例触发键
---

# 候选/录音残留吞下一用例触发键

- **症状**：后续用例首按无反应
- **根因**：状态机『活动会话只认会话 IC』+残留 candidates
- **约束规则**：每用例收尾 back_to_idle() 收敛循环（三次踩坑固化为公共函数）
- **来源**：r24/r34/r37 三连
- **验证**：连续用例稳定
