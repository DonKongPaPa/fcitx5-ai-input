---
id: x-satellite-or-no-pointer
category: x11
title: satellite 0.8.2 不向 override-redirect 窗投递指针事件
---

# satellite 0.8.2 不向 override-redirect 窗投递指针事件

- **症状**：X 卡片可见（合成正常）但 hover 永不触发；独立最小 OR 探针窗同样零事件（甚至不被合成）
- **根因**：satellite 对 OR 窗的 wayland popup 不转发 wl_pointer（上游已知 X11 弹窗限制；niri 文档明示）
- **约束规则**：X 卡交互断言走键盘路径（数字键/回车）；指针链留 'X 指针 enter' 日志作能力探测，卫星修复后用例自动升级；宿主机 WPS 卡 hover 同样不可用属上游限制，勿在 addon 侧修
- **来源**：x6 两轮最小探针复现（2026-08-27，satellite 0.8.2-1）
- **验证**：e2e x6-xwayland-pointer
