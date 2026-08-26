---
id: bd-build-in-tmp
category: build-deploy
title: 容器内 /tmp 干净构建防时间戳跳过
---

# 容器内 /tmp 干净构建防时间戳跳过

- **症状**：改了代码 make 说无需重编
- **根因**：挂载卷时间戳漂移致 cMake/make 跳过
- **约束规则**：cmake -B /tmp/build；编译错误要确认 0 error（管道会吞退出码）
- **来源**：build.sh 结构+教训
- **验证**：构建日志
