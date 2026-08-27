---
id: wl-per-surface-state-rebuild
category: wayland
title: per-surface 状态必须随 surface 重建全量重放
---

# per-surface 状态必须随 surface 重建全量重放

- **症状**：切应用后卡片放大 scale 倍/鼠标失灵/点不进
- **根因**：viewport destination、fractional 监听、input region 都是 per-surface 的；重建后依赖『首次流程设过』必失效
- **约束规则**：surface 重建路径全量重放 show 的全部 surface 级副作用（destination/input region/可见帧）
- **来源**：experiment-007 教训条；viewport destination 修复（切应用放大+鼠标灭）
- **验证**：c5/c6 交互闭环
