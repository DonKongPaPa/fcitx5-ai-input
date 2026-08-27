---
id: wl-state-atomic-with-buffer
category: wayland
title: 表面状态变更须与承载 buffer 原子成对
---

# 表面状态变更须与承载 buffer 原子成对

- **症状**：resize/移动时卡片跳闪 1-2 帧（旧 buffer 被拉伸）
- **根因**：急切改 viewport destination 而新尺寸 buffer 下一帧才 commit
- **约束规则**：destination 只与匹配尺寸 buffer 同一 commit 下发（syncViewport 统一收口全部 commit 点）
- **来源**：fix/resize-flicker
- **验证**：录像逐帧 vision 复核
