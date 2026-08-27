---
id: x-satellite-root-origin
category: x11
title: satellite 顶层 X 窗 root 摆位随版本变：0.3 恒 (0,0)，0.8.2 按合成器布局定位
---

# satellite 顶层 X 窗 root 摆位随版本变：0.3 恒 (0,0)，0.8.2 按合成器布局定位

- **症状**：按旧定案『窗口局部=X 根坐标』理解 dbus 矩形/父窗钳制框，0.8.2 下钳制框整体错位，卡片被推出窗外（scale 越大越远）
- **根因**：satellite 0.3 无 WM 布局顶层窗恒 (0,0)；0.8.2 会把顶层窗按合成器给的布局位置摆进 X root 空间（容器 niri 实测 testapp 在 root +962+28，两档 scale 相同）
- **约束规则**：矩形/钳制一律以 xcb_translate_coordinates 实测窗口 root 原点为准，不携带版本假设
- **来源**：0.3.0.36 右列错位定案（恒 0,0）→ feat/x-gtkscale-diagnosis 复测证伪（2026-08-27）
- **验证**：artifacts/gtkscale/*/xwininfo-app-before.txt
