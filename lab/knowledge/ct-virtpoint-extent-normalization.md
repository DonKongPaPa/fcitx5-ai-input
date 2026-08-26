---
id: ct-virtpoint-extent-normalization
category: container-test
title: virtpoint 坐标经 extent 归一化（分辨率无关）
---

# virtpoint 坐标经 extent 归一化（分辨率无关）

- **症状**：换分辨率后点击落点漂移
- **根因**：motion_absolute 按 extent 归一
- **约束规则**：用例坐标保持 extent 1280x720 语义（分数位置），物理分辨率变了也命中
- **来源**：1080p 迁移零改动验证
- **验证**：1080p 套件全绿
