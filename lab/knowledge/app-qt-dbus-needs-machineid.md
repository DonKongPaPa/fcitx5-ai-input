---
id: app-qt-dbus-needs-machineid
category: app-behavior
title: Qt 的 QDBusConnection 需要 /etc/machine-id
---

# Qt 的 QDBusConnection 需要 /etc/machine-id

- **症状**：Qt 应用启动即 abort（容器）
- **根因**：QtDBus 缺 machine-id 直接崩
- **约束规则**：run 脚本补写 /etc/machine-id
- **来源**：r34 教训
- **验证**：c5 testapp-qt
