---
id: ct-grep-q-sigpipe
category: container-test
title: printf|grep -q 早退撞 SIGPIPE——pipefail 下大窗口恒假败
---

# printf|grep -q 早退撞 SIGPIPE——pipefail 下大窗口恒假败

- **症状**：断言四条件全在日志里、用例仍红（gnome 28MB journal 时）
- **根因**：grep -q 首个匹配即退出，printf 继续写被 SIGPIPE；set -o pipefail 把整条管线判非零
- **约束规则**：grep PATTERN <<<"$var" 替代 printf|grep 管线（无管道无此雷）；凡 pipefail 套件禁用 |grep -q 组合
- **来源**：gnome c14 两轮假败定位（2026-08-27），67 处全量替换
- **验证**：三环境 gate 全绿
