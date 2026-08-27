---
id: wl-scale-from-zxdg-output
category: wayland
title: 精确 scale 用 zxdg-output 推导
---

# 精确 scale 用 zxdg-output 推导

- **症状**：分数 scale 下缓冲与窗口比例错、卡片等比缩水
- **根因**：wl_output 整数 scale 与真实分数 scale 不符
- **约束规则**：scale()=zxdg logical_size ÷ wl_output mode 物理尺寸；绑定全部输出+surface enter 跟踪所在屏
- **来源**：染色法破案（6525f63）+ 多输出重构（3b48ddb）
- **验证**：容器真 1.5/2.0 双绿
