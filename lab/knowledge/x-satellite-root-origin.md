---
id: x-satellite-root-origin
category: x11
title: satellite 顶层 X 窗 root 摆位随版本变：0.3 恒 (0,0)，0.8.2 按合成器布局定位
---

# satellite 顶层 X 窗 root 摆位随版本变：0.3 恒 (0,0)，0.8.2 按合成器布局定位

- **症状**：按旧定案『窗口局部=X 根坐标』理解 dbus 矩形/父窗钳制框，0.8.2 下钳制框整体错位，卡片被推出窗外（scale 越大越远）
- **根因**：satellite 0.3 无 WM 布局顶层窗恒 (0,0)；0.8.2 双向维护『X root=屏幕物理』：toplevel 的 X 位置由合成器 configure 回写（pending.x×scale+输出偏移，niri 逻辑 (481,14)×2=实测 +962+28），OR 弹窗转宿主 popup 时 offset=(X 坐标−输出偏移)/scale（server/mod.rs reconfigure_window）
- **约束规则**：矩形/钳制一律以 xcb_translate_coordinates 实测窗口 root 原点为准，不携带版本假设；X root 物理坐标可直接当屏幕坐标用
- **来源**：0.3.0.36 右列错位定案（恒 0,0）→ feat/x-gtkscale-diagnosis 复测证伪 + satellite v0.8.2 源码（2026-08-27）
- **验证**：artifacts/gtkscale/*/xwininfo-app-before.txt
