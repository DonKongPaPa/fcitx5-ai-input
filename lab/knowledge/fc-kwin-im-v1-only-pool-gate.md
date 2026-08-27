---
id: fc-kwin-im-v1-only-pool-gate
category: fcitx-api
title: 嵌套 kwin 只有 input-method v1——shm 池门控被卡死
---

# 嵌套 kwin 只有 input-method v1——shm 池门控被卡死

- **症状**：kde 环境 popup 永远 not ready（s2/c8-c11/x 组全灭），journal 无 shm pool ready
- **根因**：popup 自建连接用 zwp_input_method_manager_v2 global 作'IM 连接'判据并门控 shm 池建立；kwin 只广播 v1（wayland-info 实测），池永不建
- **约束规则**：池门控只看 compositor+shm；v1 合成器上 input-popup 是 v2 特性，ensurePopup 取不到 IM proxy 自然降级 layer——能力判定放使用处不放池建立处
- **来源**：feat/test-scenarios-complete kde 三轮定位（2026-08-27）
- **验证**：gate kde 26/26
