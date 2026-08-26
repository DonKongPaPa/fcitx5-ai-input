---
id: fc-dbus-im-protocol-paths
category: fcitx-api
title: dbus 前端 IM 协议路径与接口
---

# dbus 前端 IM 协议路径与接口

- **症状**：CreateInputContext 报 UnknownObject
- **根因**：主总线 org.fcitx.Fcitx5 上对象路径是 /org/freedesktop/portal/inputmethod；/inputmethod 只在 portal 总线 org.freedesktop.portal.Fcitx 上；接口 org.fcitx.Fcitx.InputMethod1/InputContext1
- **约束规则**：主总线用 /org/freedesktop/portal/inputmethod；IC 方法 ProcessKeyEvent(uuubu)→b、FocusIn/Out、SetCursorRect(iiii)、SelectCandidate(i)；CommitString(s) 信号
- **来源**：dbusfrontend.cpp 5.1.21 源码 + ic-sim 实测
- **验证**：addon-test a2
