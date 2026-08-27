---
id: bd-setcap-strip
category: build-deploy
title: 合成器二进制的 cap_sys_nice 需移除
---

# 合成器二进制的 cap_sys_nice 需移除

- **症状**：rootless 容器里 sway/kwin exec EPERM
- **根因**：包自带文件能力 rootless 无
- **约束规则**：镜像构建时 setcap -r /usr/sbin/sway 等
- **来源**：Containerfile.host
- **验证**：容器起得来
