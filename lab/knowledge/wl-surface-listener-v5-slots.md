---
id: wl-surface-listener-v5-slots
category: wayland
title: wl_surface listener v5 槽位不能留 NULL
---

# wl_surface listener v5 槽位不能留 NULL

- **症状**：分数 scale 下合成器发 preferred_buffer_scale 即 abort
- **根因**：listener 函数指针槽为 NULL 时 libwayland 直接 abort（协议版本升档新增事件）
- **约束规则**：listener 结构体全部槽位显式填（哪怕空 lambda）；wl_seat name 同理
- **来源**：2026-08-25 多输出版崩溃
- **验证**：NIRI_TEST_SCALE=1.5/2.0 全套件
