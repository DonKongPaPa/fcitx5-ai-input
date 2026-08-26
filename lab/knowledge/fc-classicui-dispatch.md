---
id: fc-classicui-dispatch
category: fcitx-api
title: classicui 对 dbus+wayland IC 强制 X11 UI（上游自认位置错）
---

# classicui 对 dbus+wayland IC 强制 X11 UI（上游自认位置错）

- **症状**：以为 classicui 对 gte 类应用有精确定位手段
- **根因**：classicui.cpp update() 路由 dbus IC 到 X11 UI；xcbinputwindow 无坐标翻译；上游注释原话 position will be wrong anyway
- **约束规则**：对标 classicui 时按前端分流：wayland_v2=合成器 popup 精确；dbus=同样拿不到窗口原点（我们 overlay/X 路径已是同类最优）
- **来源**：实验 008 定案
- **验证**：surface-test 并排对比
