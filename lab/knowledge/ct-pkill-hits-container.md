---
id: ct-pkill-hits-container
category: container-test
title: 宿主 pkill 杀容器内同名进程
---

# 宿主 pkill 杀容器内同名进程

- **症状**：套件从某刻起全用例零信号式假失败
- **根因**：rootless 容器进程同 UID 宿主可见；pkill -x fcitx5 波及容器
- **约束规则**：动宿主 fcitx5 前 podman ps 查活跃套件；部署与测试互斥
- **来源**：19/37 假失败定案
- **验证**：-
