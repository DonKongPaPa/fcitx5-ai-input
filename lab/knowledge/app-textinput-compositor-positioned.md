---
id: app-textinput-compositor-positioned
category: app-behavior
title: wayland 原生应用走 text-input 才有合成器级精确定位
---

# wayland 原生应用走 text-input 才有合成器级精确定位

- **症状**：GTK_IM_MODULE=fcitx 全局设置下 wayland 应用全走 dbus（拿不到原点）
- **根因**：text-input-v3 → wayland_v2 IC → input popup 由合成器定位（右列/浮动/多输出全对）
- **约束规则**：环境层正解：去掉全局 IM_MODULE（X 应用回落 XIM 仍可）；单应用可 GDK_BACKEND=x11 进 X 精确路径
- **来源**：实验 008 结论
- **验证**：surface-test 对照
