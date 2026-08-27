---
id: ct-skip-false-green
category: container-test
title: 守卫恒假→静默跳过→假绿
---

# 守卫恒假→静默跳过→假绿

- **症状**：20/20 全绿但 4 个用例实际没跑
- **根因**：sed 批量改动误伤 [ -x path ] 测试成四参数恒假
- **约束规则**：结果核查必须含『跳过』检测；批量 sed 后 grep 改动行；跳过分支文案统一可扫描
- **来源**：timeout sed 事故
- **验证**：结果审计脚本/人工
