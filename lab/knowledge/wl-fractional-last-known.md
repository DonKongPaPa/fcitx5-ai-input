---
id: wl-fractional-last-known
category: wayland
title: 新 surface fractional 未到时用上次值兜底
---

# 新 surface fractional 未到时用上次值兜底

- **症状**：重启后第二个应用起卡片放大 2x
- **根因**：layer surface 无 fractional 事件时落到 wl_output 整数 scale（ceil=2）
- **约束规则**：缓存 lastFscaleNum_，新 surface 事件未到时优先于整数兜底
- **来源**：多屏混 scale 修复 b3ff816
- **验证**：多输出/切应用场景
