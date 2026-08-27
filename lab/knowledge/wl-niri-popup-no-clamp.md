---
id: wl-niri-popup-no-clamp
category: wayland
title: niri 不替 input popup 滑位/钳制
---

# niri 不替 input popup 滑位/钳制

- **症状**：光标下方放不下时卡片出屏不可见
- **根因**：niri 的 popup 定位不做越界滑动（ConstraintAdjustment 不生效于该路径）
- **约束规则**：自己翻转/钳制：下方放不下翻上方，再钳入可见区
- **来源**：ghostty 末行出屏修复链
- **验证**：surface-test 末行场景
