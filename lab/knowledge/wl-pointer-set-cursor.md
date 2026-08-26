---
id: wl-pointer-set-cursor
category: wayland
title: pointer enter 后必须 set_cursor
---

# pointer enter 后必须 set_cursor

- **症状**：鼠标移到卡片上指针消失
- **根因**：Wayland 协议要求客户端在 enter 后主动设置光标，否则合成器隐藏
- **约束规则**：seat capabilities 得指针后进 enter 时 set_cursor（cursor-shape-v1 set_shape DEFAULT）
- **来源**：宿主机『卡上无鼠标指针』修复
- **验证**：surface-test 场景人工/截图
