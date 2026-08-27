---
id: bd-journal-user-restarts
category: build-deploy
title: 用户会自行重启 fcitx5（终端启动无 journal）
---

# 用户会自行重启 fcitx5（终端启动无 journal）

- **症状**：对账时找不到测试期日志
- **根因**：用户排障习惯+终端启动 stderr 不进 journal
- **约束规则**：对账前先 pgrep 看 fcitx5 起始时间；日志缺失不等于没发生
- **来源**：多次对账经验
- **验证**：-
