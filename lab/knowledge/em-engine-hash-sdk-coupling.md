---
id: em-engine-hash-sdk-coupling
category: embedder
title: 引擎 .so 必须与构建 kernel 的 SDK 同 hash
---

# 引擎 .so 必须与构建 kernel 的 SDK 同 hash

- **症状**：运行时引擎握手失败/渲染异常
- **根因**：libflutter_engine.so 按 engine hash 发布；kernel_blob 必须同 SDK 产出
- **约束规则**：fetch 脚本从 SDK 的 engine-dart-sdk.stamp 取 hash；容器化后固定取镜像内 pin 版 SDK 的 stamp
- **来源**：fetch-flutter-embedder.sh
- **验证**：引擎启动日志
