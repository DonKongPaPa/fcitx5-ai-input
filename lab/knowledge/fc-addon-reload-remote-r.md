---
id: fc-addon-reload-remote-r
category: fcitx-api
title: 容器里 fcitx5-remote -r 不触发 addon reloadConfig
---

# 容器里 fcitx5-remote -r 不触发 addon reloadConfig

- **症状**：改文件+remote -r 后配置未生效
- **根因**：该路径只重载部分配置（容器实测 addon 无 config-reloaded 日志）
- **约束规则**：测试改配置走 SetConfig（字符串值）；文件直改须重启 fcitx5
- **来源**：r36 调查
- **验证**：config-reloaded 日志
