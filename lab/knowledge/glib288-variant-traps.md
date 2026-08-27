---
id: glib288-variant-traps
category: container-test
title: glib 2.88 GVariant 三个坑（ic-sim 实证）
---

# glib 2.88 GVariant 三个坑（ic-sim 实证）

- **症状**：builder 判无效/参数空体/子项类型断言
- **根因**：①g_variant_new("(a(ss))", builder_end产物) 把传参当 builder 判无效；②builder 直建 (a(ss)) 元组时 add("(ss)") 子项必须是完整 a(ss) 数组；③返回 (oay) 要用 (&o^ay) 解析
- **约束规则**：数组参数用 g_variant_new_tuple(&array_variant, 1) 构造（无格式解析全绕开）；最小复现程序 /tmp/gvariant-repro*.c 三轮二分定位
- **来源**：ic-sim 开发（2026-08-26 晚）
- **验证**：addon-test 6/6
