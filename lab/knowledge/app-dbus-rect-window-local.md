---
id: app-dbus-rect-window-local
category: app-behavior
title: DBus 前端矩形=窗口局部（原点结构性缺失）
---

# DBus 前端矩形=窗口局部（原点结构性缺失）

- **症状**：右列/浮动窗口卡片整体偏左
- **根因**：GTK/Qt 经 dbus 报的 cursorRect 不含窗口原点；Wayland 不暴露他窗位置
- **约束规则**：铺满输出/左列时 rect≈输出坐标（准）；半宽列 best effort 或走环境层 text-input 正解
- **来源**：gte 截图对账破案
- **验证**：c5 maximize 场景
