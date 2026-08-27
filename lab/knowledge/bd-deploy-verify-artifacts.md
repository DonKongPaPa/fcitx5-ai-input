---
id: bd-deploy-verify-artifacts
category: build-deploy
title: 上机前验证产物：readelf/ldd -r/字符串
---

# 上机前验证产物：readelf/ldd -r/字符串

- **症状**：旧二进制仍在跑/漏符号上机崩
- **根因**：乐观假设
- **约束规则**：装后 grep -a 新日志串（中文串 strings 看不见）+ maps 核对；smoke 已加 ldd -r 拦截
- **来源**：验证纪律+崩机教训
- **验证**：部署后检查单
