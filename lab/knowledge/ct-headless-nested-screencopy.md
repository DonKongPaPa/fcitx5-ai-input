---
id: ct-headless-nested-screencopy
category: container-test
title: 嵌套 niri 的 screencopy 不出帧，录屏对宿主合成器
---

# 嵌套 niri 的 screencopy 不出帧，录屏对宿主合成器

- **症状**：录屏黑屏/无帧
- **根因**：嵌套 winit 后端不支持 screencopy
- **约束规则**：grim/wf-recorder 全部指向 CAGE_SOCK（宿主 sway 的 wayland-N）
- **来源**：cage→sway 迁移保持
- **验证**：截图非空
