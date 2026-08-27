---
id: ct-satellite-nested-container
category: container-test
title: xwayland-satellite 可挂嵌套合成器链（容器 X 仿真）
---

# xwayland-satellite 可挂嵌套合成器链（容器 X 仿真）

- **症状**：（非坑，是可行性定案）X 路径（历史 8 类 bug）此前只能宿主机验证
- **根因**：sway(headless)→niri 嵌套→satellite 作为 niri 的 wayland 客户端→X app 全链可用：_NET_ACTIVE_WINDOW 判据/父窗几何/XShm/ARGB 全真实工作
- **约束规则**：start-niri.sh 在 niri socket 就绪后启 satellite，轮询 /tmp/.X11-unix 出 socket 再 export DISPLAY（须在 start_fcitx5 前——xcb 模块要吃到）；GDK_BACKEND=x11 GTK_IM_MODULE=fcitx 跑 testapp 即 WPS 同型拓扑
- **来源**：feat/xwayland-test 冒烟一轮通过（2026-08-27）
- **验证**：e2e X 组 x1-x5
