---
id: x-satellite-parent-bounds
category: x11
title: OR 卡片必须钳入聚焦 X 顶层窗范围
---

# OR 卡片必须钳入聚焦 X 顶层窗范围

- **症状**：卡片映成独立顶层窗→niri 平铺到别处/抢键盘焦点→会话卡死
- **根因**：卡片越出父窗（或 X 屏）时 satellite 拒绝父子化走独立窗回退
- **约束规则**：queryFocusGeometryLocked 实时取父窗尺寸，先翻上方再钳窗界；X 屏只兜底（高浮动窗可超屏且弹层随窗滚动）
- **来源**：0.3.0.39 截图对账→0.3.0.40 修正
- **验证**：surface-test ghostty 类场景
