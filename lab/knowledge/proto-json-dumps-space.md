---
id: proto-json-dumps-space
category: container-test
title: python json.dumps 默认冒号后带空格，紧凑解析器全盲
---

# python json.dumps 默认冒号后带空格，紧凑解析器全盲

- **症状**：stdio 后端事件全部被静默忽略（子进程正常退出、管道数据在、C++ 侧零日志）
- **根因**：json.dumps 默认 separators=(', ', ': ')，wire 上是 "method": "asr/partial"；C++ 扁平查找按 "method":" 精确匹配落空——未知 method 按协议忽略=静默吞掉一切
- **约束规则**：后端 emit 必须 separators=(",", ":")；C++ 解析器 jsonValuePos 容忍冒号后空白（宽松在查找侧）；排查此类问题先看子进程退出码（wrapper 记 EXIT=$?），退出码 0 + 零事件=解析盲区非崩溃
- **来源**：a8 首跑失败三轮定位（2026-08-26 晚）
- **验证**：addon-test a8
