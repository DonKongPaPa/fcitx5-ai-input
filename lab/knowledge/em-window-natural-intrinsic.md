---
id: em-window-natural-intrinsic
category: embedder
title: 窗口尺寸=内在尺寸+持久帧回调（勿回测量路）
---

# 窗口尺寸=内在尺寸+持久帧回调（勿回测量路）

- **症状**：TextPainter 预测量+补偿系数方案被用户否定
- **根因**：任何字体都不该超出；测量路是死胡同
- **约束规则**：OverflowBox 无界约束自然布局+持久帧回调回读实际渲染尺寸（量化上报）+池容量桶；UI 尺寸架构定论勿回头
- **来源**：用户明确定论
- **验证**：UI 套件+golden
