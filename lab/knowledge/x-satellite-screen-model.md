---
id: x-satellite-screen-model
category: x11
title: satellite X 屏=逻辑原点+物理范围
---

# satellite X 屏=逻辑原点+物理范围

- **症状**：多输出下 X 坐标与 wayland 逻辑布局对不上
- **根因**：X root 尺寸=输出按逻辑原点摆放、范围取物理尺寸（宿主 4672×1512）
- **约束规则**：输出 X 区段判定用 logicalX/Y+physW/H；root 尺寸连接时记录
- **来源**：宿主实测定案
- **验证**：X 区段钳制用例
