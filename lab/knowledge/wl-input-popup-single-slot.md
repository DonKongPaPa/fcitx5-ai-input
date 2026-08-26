---
id: wl-input-popup-single-slot
category: wayland
title: smithay input popup 单槽 last-create-wins
---

# smithay input popup 单槽 last-create-wins

- **症状**：上屏后卡片停在旧光标；classicui 打拼音后我们不再被重定位
- **根因**：每条 zwp_input_method_v2 连接只追踪最后创建的 get_input_popup_surface；光标矩形事件只发槽内者
- **约束规则**：show 每次重建 popup（重夺槽+继承 handle 保留的最新矩形）；hide 先 attach(null)+commit 再 destroy（且防残影）
- **来源**：实验 007；c7/c8 抢槽用例
- **验证**：c8-refollow-gtk：hide 销毁×2 + 重建×1
