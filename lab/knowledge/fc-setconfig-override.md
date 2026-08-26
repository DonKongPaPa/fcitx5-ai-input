---
id: fc-setconfig-override
category: fcitx-api
title: addon 必须实现 setConfig 覆写
---

# addon 必须实现 setConfig 覆写

- **症状**：configtool 点保存毫无效果
- **根因**：基类 setConfig 默认 no-op
- **约束规则**：实现 load+migrate+save+应用（热生效项如字体/定位策略在 setConfig 内处理）
- **来源**：aiinput setConfig 实现
- **验证**：s4 顺带覆盖
