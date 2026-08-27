---
id: x-gtkscale-rect-root-coords
category: x11
title: fcitx5-gtk 矩形=X root 坐标（含窗口原点）；钳制框必须用窗口 root 范围
---

# fcitx5-gtk 矩形=X root 坐标（含窗口原点）；钳制框必须用窗口 root 范围

- **症状**：X 卡片远离光标落到窗外桌面，输出 scale 越高偏得越远；用户假设『装 fcitx5-gtk 可缓解』——vision 四图对比逐像素一致，零缓解（模块本就在位且是 rect 唯一来源）
- **根因**：gtk4 immodule 上报的 caret rect 已含窗口 root 原点（实测 rect=局部(9,1)+原点(962,28)=971,29；GDK_SCALE=2 时局部×2，980,30 自洽）；卡片是 root 的 OR 子窗，XMoveWindow 即 root 坐标——矩形与卡片同空间本可直接落点，错在父窗钳制框用 [0..W]×[0..H]（把窗口局部当 root）
- **约束规则**：queryFocusGeometryLocked 补 translate_coordinates 取窗口 root 原点，钳制/翻转框改 [winX,winX+W]×[winY,winY+H]（X 屏段保留兜底）。顺带发现：无模块（unset GTK_IM_MODULE/XMODIFIERS）时无 IC，但热键仍以陈旧 rect 弹孤儿卡片
- **来源**：feat/x-gtkscale-diagnosis（gtkscale 容器双 scale + xwininfo/vision 取证）
- **验证**：artifacts/gtkscale/*/summary.txt + xwininfo-card.txt
