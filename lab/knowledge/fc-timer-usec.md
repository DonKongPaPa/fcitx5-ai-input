---
id: fc-timer-usec
category: fcitx-api
title: addTimeEvent 用绝对 µs + setOneShot
---

# addTimeEvent 用绝对 µs + setOneShot

- **症状**：定时器不触发或语义混乱
- **根因**：sd-event 语义为绝对时间；interval 参数位是 accuracy
- **约束规则**：nowUs()+delay 形式；一次性事件补 setOneShot()
- **来源**：armRecordingWatchdog 实现
- **验证**：c3 看门狗
