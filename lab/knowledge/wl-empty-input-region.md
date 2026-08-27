---
id: wl-empty-input-region
category: wayland
title: 隐藏态必须显式清空输入区
---

# 隐藏态必须显式清空输入区

- **症状**：透明卡片区域挡住下方应用按钮
- **根因**：layer surface 输入区与像素透明度无关，不显式清空则『出现过的区域』全程可命中
- **约束规则**：创建即挂空 region；show 恢复全量（nullptr）；show 之后的 surface 交换也要重放恢复
- **来源**：r22 穿透用例；fallback 鼠标失灵修复
- **验证**：c6 隐藏后穿透断言
