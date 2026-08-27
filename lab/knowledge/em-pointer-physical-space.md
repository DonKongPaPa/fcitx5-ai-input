---
id: em-pointer-physical-space
category: embedder
title: FlutterPointerEvent 坐标必须是物理像素
---

# FlutterPointerEvent 坐标必须是物理像素

- **症状**：指针命中位置缩到左上 1/scale（悬停错行/点击失灵）
- **根因**：embedder 约定 pointer 事件与 metrics 同空间（物理）；引擎内部 ÷dpr 做命中
- **约束规则**：onPointer 前乘 metrics dpr（引擎侧缓存 lastRatio_，与 metrics 同空间无竞态）
- **来源**：悬停偏移真根因收口（0.3.0.23）
- **验证**：c6 hover/点击
