---
id: fc-setconfig-string-values
category: fcitx-api
title: D-Bus SetConfig 的值必须是字符串
---

# D-Bus SetConfig 的值必须是字符串

- **症状**：int32 值被静默丢弃，落盘成默认值
- **根因**：Controller1 配置接口值类型全为 s（GetConfig 回读全带引号）
- **约束规则**：gdbus 传 <'10'> 而非 <10>
- **来源**：r36 首跑失败定案
- **验证**：GetConfig 回读对账
