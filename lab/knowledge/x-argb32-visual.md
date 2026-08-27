---
id: x-argb32-visual
category: x11
title: 32 位 ARGB visual + colormap 才有透明
---

# 32 位 ARGB visual + colormap 才有透明

- **症状**：卡片四周阴影/圆角渲染成黑边
- **根因**：24 位深度无 alpha 通道
- **约束规则**：枚举 depth-32 TrueColor visual 建独立 colormap；无则退化 root_visual 带黑边兜底
- **来源**：0.3.0.37（/tmp/xargb.c 先证）
- **验证**：透明区透出桌面非黑
