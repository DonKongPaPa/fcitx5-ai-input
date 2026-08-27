---
id: ct-stdin-consumed-by-chain
category: container-test
title: 交互容器 stdin 会被调用链吞掉
---

# 交互容器 stdin 会被调用链吞掉

- **症状**：管道喂脚本给 MODE=shell 的 bash 无输入
- **根因**：su/dbus-run-session 链消耗 stdin
- **约束规则**：探针脚本用文件挂载注入，不走 stdin
- **来源**：probe-r36 折腾记录
- **验证**：-
