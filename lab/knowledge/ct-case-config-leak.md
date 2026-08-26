---
id: ct-case-config-leak
category: container-test
title: 用例改配置必须还原到产品默认（不是任意安全值）
---

# 用例改配置必须还原到产品默认（不是任意安全值）

- **症状**：X 组单跑全绿、全量跑全灭（X 分支整组静默关闭走 overlay 兜底）
- **根因**：c5 尾部把 DbusPosition 还原成 bottom——那是旧默认值；产品默认已改 follow，泄漏让 c5 之后所有依赖 follow 的用例静默变行为
- **约束规则**：用例内 set_cfg 的还原值抄产品默认（config 头里的 default），不许凭记忆写'安全值'；对配置敏感的用例组开头防御性自设基线（X 组自设 follow）；新用例组单跑绿+全量跑绿都过了才算绿
- **来源**：feat/xwayland-test 全量门禁 21/26 两轮定位（2026-08-27）
- **验证**：gate-merge 26/26×2
