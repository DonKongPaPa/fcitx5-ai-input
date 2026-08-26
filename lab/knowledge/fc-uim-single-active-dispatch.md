---
id: fc-uim-single-active-dispatch
category: fcitx-api
title: InputPanel 只派发给唯一活跃 UI（ui_），非全体
---

# InputPanel 只派发给唯一活跃 UI（ui_），非全体

- **症状**：Category=UI 注册成功（构造/update(StatusArea) 有日志）但打字组合永不到达 update(InputPanel)
- **根因**：UserInterfaceManager::updateSingleComponent 只调 ui_ 单指针（非 uis_ 全表）；且 IC 带 ClientSideInputPanel 能力位时走 updateClientSideUIImpl 完全绕过 UI 插件
- **约束规则**：测试环境 --disable=classicui,kimpanel 保证选中自己；keyboard-us 不产生组合——必须组内加 pinyin 并 SetCurrentIM（要求目标已在组列表，组名从总线取：'Default' 被 zh_CN locale 翻译）
- **来源**：uim.cpp/userinterfacemanager.cpp 5.1.21 源码；a7 排障（2026-08-26）
- **验证**：addon-test a7
