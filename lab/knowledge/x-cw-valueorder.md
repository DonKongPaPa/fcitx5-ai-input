---
id: x-cw-valueorder
category: x11
title: xcb CreateWindow 值列表必须按 CW 位序
---

# xcb CreateWindow 值列表必须按 CW 位序

- **症状**：BadValue、窗口从未创建（创建日志是请求后乐观打印）
- **根因**：value 数组按 mask 位序解包；顺序写反=把事件掩码大整数当布尔读
- **约束规则**：严格按 border_pixel<save_under<override_redirect<event_mask<colormap 顺序；独立小程序先证再移植
- **来源**：0.3.0.36 总根源破案（/tmp/xorder.c）
- **验证**：X OR 卡片窗创建日志 + 零 X 错误
