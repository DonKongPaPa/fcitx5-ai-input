---
id: x-satellite-root-origin
category: x11
title: satellite 把所有顶层 X 窗摆在根 (0,0)
---

# satellite 把所有顶层 X 窗摆在根 (0,0)

- **症状**：X 应用的 mapToGlobal 是窗口局部物理值，右列窗口矩形整体偏左
- **根因**：xwayland-satellite 无 WM 布局，顶层窗根坐标恒 (0,0)；真实原点由 OR 窗父子化时合成器叠加
- **约束规则**：X 应用 dbus 矩形按『窗口局部=X 根坐标』理解；卡片走 X OR 窗让 satellite 挂靠叠加原点
- **来源**：右列错位根因定案（query tree 实测）
- **验证**：c5 贴光标 + WPS 左右列
