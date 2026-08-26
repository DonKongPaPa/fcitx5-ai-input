---
id: x-error-events-not-silent
category: x11
title: X 错误事件不能静默吞
---

# X 错误事件不能静默吞

- **症状**：『完全没效果』类问题无任何日志线索
- **根因**：response_type==0 的错误事件被直接 free
- **约束规则**：错误事件限流打日志（code+seq）；BadValue/BadGC/BadDrawable 一眼定位
- **来源**：0.3.0.35 加 [x11diag] 日志
- **验证**：journal 无 X 错误即健康
