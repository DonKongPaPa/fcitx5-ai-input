---
id: fc-uieventloop-include
category: fcitx-api
title: EventLoop 完整定义在 event.h
---

# EventLoop 完整定义在 event.h

- **症状**：编译报不完整类型
- **根因**：eventloopinterface.h 只有抽象接口
- **约束规则**：#include <fcitx-utils/event.h>
- **来源**：r31 开发记录
- **验证**：编译
