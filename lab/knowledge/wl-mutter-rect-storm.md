---
id: wl-mutter-rect-storm
category: wayland
title: mutter 每帧重发同值 text_input_rectangle（矩形风暴）
---

# mutter 每帧重发同值 text_input_rectangle（矩形风暴）

- **症状**：gnome 全程 12.6 万条 rect 日志（~300/s），事件循环被拖死、D-Bus 触发调用超时
- **根因**：mutter 对 input popup surface 逐帧重发相同矩形；addon 逐条处理+记日志
- **约束规则**：popupRectangle 同值去重（零处理）；去重状态必须随 popup 重建重置——合成器对新 popup 重发同值矩形，不复位则首个事件被吞、hasCursorRect_/sawRealRect_ 永不置位
- **来源**：feat/test-scenarios-complete gnome c7/c10 排障（2026-08-27）
- **验证**：gate gnome 26/26，rect 日志 12.6万→3 条
