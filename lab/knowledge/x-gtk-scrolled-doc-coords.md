---
id: x-gtk-scrolled-doc-coords
category: x11
title: GTK 滚动文档坐标虚报
---

# GTK 滚动文档坐标虚报

- **症状**：末行输入时光标矩形 y 超窗口高（如 1080 高的窗报 2250）
- **根因**：GtkTextView 内层控件 allocation 是全文档高度，非视口
- **约束规则**：矩形超窗高按虚报处理（翻转+钳制兜住）；勿拿它当光标真值
- **来源**：ghostty/gte 末行 rect 对账
- **验证**：surface-test 长文档场景
