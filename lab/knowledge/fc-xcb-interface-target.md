---
id: fc-xcb-interface-target
category: fcitx-api
title: Fcitx5::Module::XCB 是 INTERFACE 目标
---

# Fcitx5::Module::XCB 是 INTERFACE 目标

- **症状**：宿主首调即 symbol lookup error 崩溃，容器测不出
- **根因**：该 CMake 目标只给头文件；libxcb/libxcb-shm 必须 pkg_check_modules 显式链
- **约束规则**：链接xfcitx 模块依赖后必做 readelf -d 检查 + smoke 加 ldd -r 拦截
- **来源**：0.3.0.27 崩机教训
- **验证**：smoke.sh ldd -r
