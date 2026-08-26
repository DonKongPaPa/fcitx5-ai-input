---
id: bd-headless-popup-guard
category: build-deploy
title: headless 环境 popup 分支必须判空 im_
---

# headless 环境 popup 分支必须判空 im_

- **症状**：无显示容器 fcitx5 会话即 SIGSEGV
- **根因**：ensurePopup popup 分支裸调 zwp_input_method_v2_get_input_popup_surface(im_=null)
- **约束规则**：else if (im_) 守卫 + 无处可挂仅记日志 return false——会话逻辑不受影响
- **来源**：addon-test 容器前置修复
- **验证**：addon-test a2 全流程
