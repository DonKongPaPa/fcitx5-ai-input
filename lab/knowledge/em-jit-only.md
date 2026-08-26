---
id: em-jit-only
category: embedder
title: 官方 embedder 只有 JIT 变体
---

# 官方 embedder 只有 JIT 变体

- **症状**：想要 AOT
- **根因**：linux-x64-embedder.zip 只出 JIT 工件
- **约束规则**：kernel_blob + icudtl.dat 路线；无 AOT snapshot 字段
- **来源**：fetch-flutter-embedder.sh 注释
- **验证**：构建产物清单
