---
id: ct-wfrecorder-kill9
category: container-test
title: 1080p 下 wf-recorder 无视 SIGINT/SIGTERM
---

# 1080p 下 wf-recorder 无视 SIGINT/SIGTERM

- **症状**：rec_stop 的 wait 永久挂起（套件卡死 40 分钟）
- **根因**：高分辨率无损编码器不返回事件循环
- **约束规则**：SIGINT 宽限→kill -9 兜底；编码参数 -p crf=30 -r 24 降负载
- **来源**：sway 1080p 首轮事故
- **验证**：套件按时完成
