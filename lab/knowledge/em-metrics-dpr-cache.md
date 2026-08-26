---
id: em-metrics-dpr-cache
category: embedder
title: updateMetrics 时缓存 dpr 供 pointer 换算
---

# updateMetrics 时缓存 dpr 供 pointer 换算

- **症状**：与 popup scale 查询产生竞态错比
- **根因**：metrics dpr 与表面 scale 到达时序不同
- **约束规则**：dpr 只记 metrics 侧（lastRatio_），pointer 用它换算
- **来源**：同 pointer-physical-space
- **验证**：双 scale 套件
