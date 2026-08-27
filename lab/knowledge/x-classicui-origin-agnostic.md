---
id: x-classicui-origin-agnostic
category: x11
title: classicui X 定位原点无关：rect 原样用+只钳 X 屏；窗口缩放走 Xft.dpi/96
---

# classicui X 定位原点无关：rect 原样用+只钳 X 屏；窗口缩放走 Xft.dpi/96

- **症状**：（机制定案，对照我们父窗钳制翻车）classicui 在 Xwayland、任意 scale 下定位与缩放都正确
- **根因**：xcbinputwindow.cpp updatePosition：x=cursorRect.left() 原样（rect 已是 root 物理坐标），root 的 OR 子窗直接摆 root 坐标，只钳 randr 屏幕矩形、无父窗钳制——不需要知道应用窗在哪；窗口缩放=xcbui scaledDPI（isXWayland 时跳过逐屏 DPI 只认 Xft.dpi）→XCBWindow 物理=逻辑×dpi/96+cairo device_scale；Xft.dpi 启动时读取（容器晚于 fcitx5 启动注入不重读）
- **约束规则**：X 卡片定位向 classicui 对齐：rect 原样+X 屏钳制即原点无关；父窗约束真要保留必须 translate_coordinates 取真实 root 范围。历史加父窗钳制的两个案例（ghostty 末行出屏、GTK 滚动虚报）其实都已超 X 屏——X 屏钳制本来就兜得住
- **来源**：feat/x-gtkscale-diagnosis C 阶段对照（scale2.0 同场景同 rect=980,30：classicui 候选窗 (980,94) 贴光标 0px，我们卡片被钳到 (60,110)）+ fcitx5 5.1.x 源码
- **验证**：artifacts/gtkscale/gtkscale-20260827-132217-2.0/xwininfo-classicui.txt + vision 对照
