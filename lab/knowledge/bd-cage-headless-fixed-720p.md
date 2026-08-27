---
id: bd-cage-headless-fixed-720p
category: build-deploy
title: cage headless 输出 1280×720 硬编码
---

# cage headless 输出 1280×720 硬编码

- **症状**：想要 1080p 无门
- **根因**：cage 源码写死 headless 输出尺寸
- **约束规则**：用 sway 托管（output HEADLESS-1 resolution 1920x1080）
- **来源**：1080p 迁移
- **验证**：截图 1920×1080
