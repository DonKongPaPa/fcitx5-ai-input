---
id: wl-preedit-needs-updatepreedit
category: wayland
title: client preedit 必须经 updatePreedit() 送达应用
---

# client preedit 必须经 updatePreedit() 送达应用

- **症状**：设了 preedit 应用毫无反应
- **根因**：updateUserInterface 只刷 UI 插件，不产生 UpdatePreeditEvent→waylandim→应用链路
- **约束规则**：推组合文本必须 ic->updatePreedit()；探针/内联预览全靠它
- **来源**：可见组合文本实时跟随定案
- **验证**：c9 探针+矩形事件断言
