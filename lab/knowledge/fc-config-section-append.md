---
id: fc-config-section-append
category: fcitx-api
title: 配置文件追加键不能落进节内
---

# 配置文件追加键不能落进节内

- **症状**：追加的配置项静默失效
- **根因**：ini 末尾若残留 [节]，追加行被解析成节键
- **约束规则**：程序化改配置先检查节边界；用 SetConfig 而非 echo >>
- **来源**：WPS 首测未跟随的全部原因
- **验证**：configtool 回读
