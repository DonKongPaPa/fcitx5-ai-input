---
id: ct-injectkey-vs-simulatekey
category: container-test
title: SimulateKey 直喂状态机；InjectKey 走真实事件管线
---

# SimulateKey 直喂状态机；InjectKey 走真实事件管线

- **症状**：用 SimulateKey 喂字母拼音引擎看不见
- **根因**：TestService::SimulateKey 绕过 watcher/引擎
- **约束规则**：验证拦截/透传语义、拼音组合必须 InjectKey
- **来源**：r25 坑
- **验证**：c7/c8 拼音幕
