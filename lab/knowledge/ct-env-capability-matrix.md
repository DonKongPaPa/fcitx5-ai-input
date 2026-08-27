---
id: ct-env-capability-matrix
category: container-test
title: 合成器能力矩阵：popup 与指针注入是两个独立维度
---

# 合成器能力矩阵：popup 与指针注入是两个独立维度

- **症状**：同是'非 niri'环境，断言分档错位（gnome 有 popup 无指针；kwin 两者皆无）
- **根因**：input-method-v2：niri✓ mutter✓ kwin✗(仅 v1)；wlr-virtual-pointer：niri✓ kwin✗ mutter 有协议但嵌套无头不投递（点击零焦点变化实证）
- **约束规则**：IS_POPUP_ENV（kde 排除）与 IS_POINTER_ENV（仅 niri）独立判定；wayland-info 实测为准，协议在≠投递通；mutter 无头还有窗口焦点漂移+chromium 偶发 crashpad，用例需触发重试与崩溃感知档
- **来源**：feat/test-scenarios-complete wayland-info 双环境探测（2026-08-27）
- **验证**：三环境 26/26 各走各档
