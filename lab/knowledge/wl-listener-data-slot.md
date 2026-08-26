---
id: wl-listener-data-slot
category: wayland
title: libwayland listener data 与 proxy user_data 同槽
---

# libwayland listener data 与 proxy user_data 同槽

- **症状**：surface enter 回调拿到的 this 是零块/野指针，SEGV 于 map 遍历
- **根因**：wl_proxy_add_listener 的 data 与 wl_proxy_set_user_data 共用同一槽；先挂 listener 再 set_user_data 会覆盖
- **约束规则**：需要两者共存时：listener data 指向自建块，块头部存 this 反向指针（compat calloc 方案）；或不用 set_user_data
- **来源**：popup_surface.cpp surfaceEnter 注释；2026-08-25 多输出重构 SEGV 定案
- **验证**：容器双 scale 套件 + 指针进 popup 不崩用例
