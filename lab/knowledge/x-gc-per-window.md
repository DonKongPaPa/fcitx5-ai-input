---
id: x-gc-per-window
category: x11
title: GC 必须随窗口销毁重建
---

# GC 必须随窗口销毁重建

- **症状**：窗重建后 put_image 全败（BadGC）
- **根因**：GC 绑定 drawable，窗口销毁后 GC 悬空
- **约束规则**：每个新窗口配新 GC；销毁时同时 xcb_free_gc
- **来源**：0.3.0.35 透明窗破案
- **验证**：同上
