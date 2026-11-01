# card-qml —— Quickshell QML 卡片原型

既定决策②（DMS 风格 QML Material 卡片 → **独立 Quickshell 实例**，非 DMS 插件）
的可行性原型。可行性优先：直接拼系统 `QtQuick.Controls.Material` 暗色组件，
不做像素打磨。协议真源 `lab/spec/protocol.md`（v1 envelope）。

## 结构

| 文件 | 职责 |
|---|---|
| `shell.qml` | Quickshell 入口：双 PanelWindow（语音卡 + 候选面板）；socket 收发与 v1 envelope 分发 |
| `Theme.qml` | Material 暗色 tokens；`theme` 事件热改字号（font_size×scale）/anim 挡位/字体 |
| `Card.qml` | 语音卡四态：recording=partial+elapsed、result=final+倒计时、candidates=列表+hover、idle |
| `Panel.qml` | rime 候选面板：preedit 分段 underline、aux_up/aux_down、candidates（label+text+comment）、横/竖排、cursor 高亮、hover 高亮、翻页 |
| `tools/feed.py` | 回放 feeder：Unix socket **服务端**，把 `lab/spec/events/*.jsonl` 灌给卡片 |

## 传输

Unix socket（`Quickshell.Io/Socket` + `SplitParser` 按行收）——qml-probe 探针
结论：Io 模块无读自身 stdin 的类型，socket 是唯一进程外通道；路径经
`AIINPUT_CARD_SOCK` 环境变量交接，QML 侧不硬编码。feeder 是服务端（**须先
listen**），卡片是客户端（断线自动重连，连上即发 `ready`）。每行一个
envelope（紧凑 JSON + `\n`）；`write()` 不自动补 `\n`，写后必须 `flush()`。

## 协议映射表（lab/spec/protocol.md v1）

### addon → ui（dir=out，shell.qml 消费）

`channel != "ui"`、`dir != "out"`、未知 method 一律忽略（向前兼容）。

| method | UI 行为 |
|---|---|
| `hello` | 记 caps；面板翻页按钮仅 caps 含 `paging` 时可见 |
| `theme` | 热改字号（font_size×scale）、anim 挡位、font_path（FontLoader）/font_family |
| `voice/recording` | Card→recording：partial + elapsed 计时 + 录音点脉动 |
| `voice/result` | Card→result：final + timeout_ms 本地倒计时（到 0 不自行 commit，上屏决策在 addon） |
| `voice/candidates` | Card→candidates：final + 列表（hover 高亮、点击回 select） |
| `voice/idle` | Card→idle 待机胶囊 |
| `panel/update` | Panel 显示；全量推送语义，缺省字段复位（不保留旧值） |
| `panel/hide` | Panel 隐藏 |
| `panel/caret` | 只收不处理（layer 重锚属 addon P4 职责，原型不做跟随） |

### ui → addon（dir=in，卡片经同一 socket 回写）

| method | 触发点 |
|---|---|
| `ready {}` | socket 连上即发 |
| `resize {w,h}` | 卡片/面板窗口尺寸变化（200ms 去抖） |
| `select {index}` | 候选行点击（Card 列表与 Panel 行通用，index=页内序号） |
| `hover {row}` | 候选行悬停进入（离开不发 -1，原型简化） |
| `navigate {delta}` | Panel 翻页按钮 / 滚轮（±1，向上滚=上一页） |
| `cancel {}` | Card result/candidates 态「取消」按钮（layer 表面无键盘焦点，Esc 不可达） |

## 演示（实机演示在宿主阶段做）

> ⚠️ 本目录是原型：**实机演示放到宿主阶段（niri 会话内）**。不要在无合成器
> 的开发机/CI 环境随手启动 quickshell；`QT_QUICK_BACKEND=software` 即可跑
> （探针已验证，无需 GL）。

```bash
# 终端 A：feeder 先起（卡片断线重连依赖服务端先 listen）
python3 card-qml/tools/feed.py lab/spec/events/voice-full.jsonl lab/spec/events/pinyin-flow.jsonl

# 终端 B：quickshell 卡片
qs -p card-qml
```

- 自定义 socket 路径：两端同设，如 `AIINPUT_CARD_SOCK=/tmp/aiinput-demo.sock`。
- 文件缺失兜底：`feed.py` 对不存在的文件回放内置最小样例集（文件名含
  `panel` 选 panel 流，否则 voice 流）；样例集可落盘：
  `python3 card-qml/tools/feed.py --write-samples /tmp/samples`。
- 观察点：终端 A 的 `RECV-IN` 行即卡片回写的 ready/resize/select/...；
  终端 B stderr 的 `CARD:` 行是卡片侧处理日志。

## 已知边界（原型如实记录）

- 语音卡与候选面板共用一个 socket 连接 → `resize{w,h}` 无法区分来源表面；
  真实拆分里每个 UI 是独立 addon 连接（见 `docs/ui-plugin-split.md`），歧义不存在。
- `font_path` 经 FontLoader 热加载，失败回落系统默认；`font_family` 与加载
  结果后到者赢。
- `cancel` 无键盘路径（WlrKeyboardFocus.None）；`panel/caret` 只收不锚。
- idle 态卡片仍占一层表面（真实版 idle 应 unmap；原型保持可见便于走查）。
- 竖排 candidates 依赖 `hello.caps` 无关，布局只看 `panel/update.layout`。
