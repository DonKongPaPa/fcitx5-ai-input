---
id: bd-local-lib-not-searched
category: build-deploy
title: ~/.local/lib 不入 addon 搜索路径
---

# ~/.local/lib 不入 addon 搜索路径

- **症状**：手工放的 .so 不被加载
- **根因**：addon 搜索路径只有 /usr、/usr/local、~/.local/share 下特定结构
- **约束规则**：部署一律走 pacman -U；验证装到位查 /proc/<pid>/maps
- **来源**：验证纪律
- **验证**：maps grep aiinput
