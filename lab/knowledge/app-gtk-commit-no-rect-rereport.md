---
id: app-gtk-commit-no-rect-rereport
category: app-behavior
title: 程序性 commit 不触发矩形重报
---

# 程序性 commit 不触发矩形重报

- **症状**：卡片『迟一步』停在上一段插入点
- **根因**：应用只在光标移动/文本变化时重报
- **约束规则**：上屏后注入 Left+Right 无净位移键对（postEvent+forwardKey）逼重报
- **来源**：r28 三轮听写对齐
- **验证**：c11 微移注入×3
