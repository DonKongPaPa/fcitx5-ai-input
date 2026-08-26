---
id: fc-input-popup-api
category: fcitx-api
title: getInputMethodV2 仅对 wayland_v2 IC 非空
---

# getInputMethodV2 仅对 wayland_v2 IC 非空

- **症状**：DBus 前端 IC 拿不到 IM proxy，input popup 路径不可达
- **根因**：waylandim 公开 API 动态_cast wayland_v2 前端 IC；dbus IC 无 IM 连接侧身份
- **约束规则**：imAvailable 判定驱动：无 proxy→overlay/X 路径；这也是 classicui 对 dbus IC 的同款行为
- **来源**：classicui 源码核读 + 实验实验 008
- **验证**：c5 overlay 日志
