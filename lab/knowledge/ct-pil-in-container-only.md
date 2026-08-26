---
id: ct-pil-in-container-only
category: container-test
title: niri 镜像内有 pillow；宿主无
---

# niri 镜像内有 pillow；宿主无

- **症状**：宿主跑像素脚本失败
- **根因**：镜像装了 python-pillow
- **约束规则**：像素断言/标注在容器内跑；宿主只有 ffmpeg/vision
- **来源**：像素断言工作流
- **验证**：-
