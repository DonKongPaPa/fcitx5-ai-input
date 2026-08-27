---
id: ct-bash-or-and-precedence
category: container-test
title: bash {A&&B||C&&D} 左结合拆散双档断言
---

# bash {A&&B||C&&D} 左结合拆散双档断言

- **症状**：双档条件（popup 环境||layer 环境）在第一档为真的环境里反而判负
- **根因**：&& 与 || 同优先级左结合：(A&&B)||C 再 &&D——D 属于第二档却对第一档结果生效
- **约束规则**：多档断言显式分组 {{一档;} || {二档;}；写完用双环境值各单测一次条件表达式
- **来源**：gnome c9 rebuild=2 rect=7 仍红的离谱现场（2026-08-27）
- **验证**：IS_POPUP_ENV 1/0 双值单测通过
