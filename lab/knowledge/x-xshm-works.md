---
id: x-xshm-works
category: x11
title: MIT-SHM 在 satellite 下可用
---

# MIT-SHM 在 satellite 下可用

- **症状**：-
- **根因**：Xwayland 共享内存扩展 v1.2 shared_pixmaps=1 可用
- **约束规则**：帧传输用 XShm PutImage 即可，无需回退纯 PutImage
- **来源**：/tmp/xshmcard.c 实证
- **验证**：X 卡片帧到达
