---
id: ct-scale-wildcard-winit
category: container-test
title: 嵌套 niri 输出名不吃 output "*" 通配
---

# 嵌套 niri 输出名不吃 output "*" 通配

- **症状**：scale 配置静默不生效，全部轮次假跑 1.0
- **根因**：winit 后端输出名（Smithay Winit Unknown）不匹配通配
- **约束规则**：同时写 output "Winit" 规则；NIRI_TEST_SCALE 透传；验证 scale 生效要查 niri msg outputs
- **来源**：容器 scale 大坑定案
- **验证**：双 scale 矩阵
