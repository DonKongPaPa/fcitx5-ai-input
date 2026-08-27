---
id: x-active-window-classifier
category: x11
title: _NET_ACTIVE_WINDOW 存在⟺聚焦应用是 X 应用
---

# _NET_ACTIVE_WINDOW 存在⟺聚焦应用是 X 应用

- **症状**：program/WM_CLASS 判 X 应用恒失败（program 恒空）
- **根因**：satellite 在 wayland 应用聚焦时清空该属性；DBus IC 的 program() 首次 FocusIn 乃至整个会话可为空
- **约束规则**：rectIsXPhysical（矩形超全部输出逻辑范围）|| 活动窗存在，任一命中即 X 路径；负结果不缓存（清除有时序竞态）
- **来源**：0.3.0.33 判据演化
- **验证**：X OR 模式进入日志
