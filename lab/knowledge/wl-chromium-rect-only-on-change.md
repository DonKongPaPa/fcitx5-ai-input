---
id: wl-chromium-rect-only-on-change
category: wayland
title: chromium 系只在文本/光标变化时报矩形
---

# chromium 系只在文本/光标变化时报矩形

- **症状**：焦点时零矩形事件，看似不支持跟随
- **根因**：chromium 不在焦点时报 text_input_rectangle，只在上屏插入/拼音组合时报
- **约束规则**：动态判断：prepare 建 popup 探测、show 仍无非零矩形→回退；上屏记账 committedInThisIC_ 下轮继承
- **来源**：r24/r26 定案
- **验证**：c7 chromium 三幕幕 2
