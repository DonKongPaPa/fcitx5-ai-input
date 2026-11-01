# QML 卡像素回传（frame-relay）设计

状态：**T1 已通（feat/qml-card-offscreen-host 分支）**。目标：**QML 卡获得
与 Flutter 卡完全同级的跟随精度**（合成器定位 input-popup surface），保留
QML Material 视觉与进程隔离（崩溃不拖垮 fcitx5）。

## 0. 实施结论（2026-11-02）

- **渲染端弃用 quickshell grab**：grabToImage 依赖合成器 expose，
  invisible/屏外 PanelWindow 回调永久丢失（wip/qml-frame-relay 存档）。
  改为独立 Qt6 离屏宿主 **aiinput-card-host**（card-qml/host/）：
  `QQuickRenderControl` + 软件后端 + `QT_QPA_PLATFORM=offscreen`，渲染全
  同步、不依赖显示服务器；QML 场景 shell-headless.qml 复用 Card/Panel/
  Theme（theme.scale 内化输出缩放，隐式尺寸即物理像素，无 dpr 协商）。
- **传输改 abstract unix socket**：filesystem socket 的 dentry 在容器
  flow 里 bind 后毫秒级被外部摘除（内核 socket 表仍监听、bind 者自身
  路径查找 ENOENT；strace 观察即消失=Heisenbug）。约定：`AIINPUT_CARD_
  SOCK` 以 `/` 开头 = filesystem（旧约定兼容），否则 = abstract 名
  （`sun_path[0]='\0'`，默认 `aiinput-card-<uid>`）。宿主侧因此用原生
  AF_UNIX + QSocketNotifier（Qt 的 QLocalSocket 对 abstract 支持未定
  文档）。
- **帧格式升级为 premultiplied BGRA 直入**（FRM 头 w/h 透传，payload
  首字节 "P6" 仍走 PPM 旧路）：修 PPM 路线的 alpha 丢失（圆角/阴影正常
  混合），零转换 memcpy 进 shm 池。
- **T1 实证**（容器 relayhost11）：abstract 双通道 75ms 内连；离屏渲染
  420x48/79/83 帧 → VoicePopup pushFrameRelay → input-popup surface 上
  屏，Material 暗色语音卡与 pinyin 候选面板截图目检通过；无双显（宿主
  零窗口）；QML 卡进程 kill 不影响 fcitx5（崩溃隔离同 M2）。
- **遗留**：ic-sim 的 rect 变更不驱动 popup 重锚（D-Bus IC 定位语义，
  exp 008 领域）——relay 帧走与 Flutter 卡完全相同的 popup 定位代码，
  跟随精度由 popup 层继承，真实应用待宿主验收。

## 1. 根因与思路

QML 卡跟随错位的根因：其 layer 窗口没有 input-popup 的定位特权，caret 只有
窗口局部坐标（Wayland 不暴露窗口原点；niri IPC 复测 2026-11-02 仍不暴露像素
位置，`tile_pos_in_workspace_view` 恒 null）。

解法：**渲染与定位分离**——QML 卡只负责「把卡片/面板画成位图」，位图回传给
VoicePopup，由它写入 **input-popup surface**（合成器贴光标，exp 007/008 的
全部成果直接复用：跟随、探针、三路径决策、知识记账一个不动）。这与
protocol.md 北极星「渲染器可插拔」同构：**Flutter 与 QML 成为可互换的渲染
后端，定位与表面宿主只有一份**。

## 2. 架构与数据流

```
QML 卡（Quickshell 进程）                     VoicePopup（fcitx5 进程）
┌──────────────────────────┐                 ┌─────────────────────────┐
│ Card/Panel QML 场景       │                 │ input-popup surface      │
│  ├ 状态更新（envelope 行）│  控制面（现状）  │ （合成器定位 = 精确跟随） │
│  ├ grabToImage() 异步     │                 │                         │
│  └ 帧 PPM ──帧 socket────┼────二进制帧─────┼─→ pushFrameBGRA()        │
│    resize{w,h} 上报       │                 │   （Dart 同款链路复用）   │
└──────────────────────────┘                 └─────────────────────────┘
```

- **控制面**：现有 Unix socket 行协议不动（voice/*、panel/*、命令回流）。
- **帧面**：第二个 Unix socket `aiinput-frame.sock`，纯二进制，与行协议
  互不阻塞。QML 卡是客户端（与服务端同一 spawn 生命周期）。
- VoicePopup 恒建（透明表面保留 = caret 源，0.4.11 现状）；帧到达即
  `pushFrameBGRA`，**上屏节奏/尺寸协商与 Dart 帧同款**（resize→
  setLogicalSize→metrics）。

## 3. 协议扩展（v1 帧通道）

帧 socket 二进制帧（无 envelope 封套，纯性能面）：

```
"FRM" u32_le w  u32_le h  u32_le size  u8 data[size]     # BGRA8888, 预乘
"BYE"                                                      # 卡片退出
```

- **格式选 BGRA 裸帧**：QImage ARGB32 内存序即 BGRA（小端），**零转换**
  直接 memcpy 进 VoicePopup 的 shm 池（与 Flutter 软渲输出同路径）。
- QML 侧取字节走 `grabToImage()` → `QImage.saveToFile("/tmp/…", "ppm")`
  → **C++ 读 PPM 解析**（PPM = 无压缩 raw，Qt 写出快；/tmp 是 tmpfs）。
  QML 无法直接从 grab result 取 bytes（QML 无字节 API），文件中转是
  最短链路；tmpfs 写 500KB/帧 @10fps ≈ 5MB/s，可承受。
- **帧节流**：状态变化即 grab + **100ms 节流 Timer**（动画期 10fps，
  原型够用；后续可调）。
- **丢帧语义**：VoicePopup 端忙即丢（协议无回执，下帧全量覆盖——与
  Flutter 帧同语义）。

## 4. QML 端改造

- **两窗口改「渲染源」角色**：PanelWindow 保留（场景宿主）但
  `visible: false`——**grabToImage 对不可见窗口内容的有效性是首个容器
  验证点**（QT 场景图对 hidden window 的渲染策略需实测；若不可行退级
  方案：窗口 map 但全透明 + 输入区域空，grab 内容 Item 树）。
- 状态更新后 grab：`showRecording/showResult/showCandidates/showIdle/
  applyUpdate` 各出口挂 grab 触发；grab 回调里 saveToFile + 帧通道发送。
- `resize{w,h}` 上报照旧（内在尺寸 = grab 尺寸）。
- **回退开关**：`QmlCardMode=direct|relay`（direct=现有直显路径保留，
  relay=帧回传）——直显路径在 FlutterCard=True 双卡对比时仍用。

## 5. 容器测试计划（沿用 qml-probe 方法学）

镜像：`aiinput-qml-probe`（niri 栈 + quickshell）。驱动：qml-card-driver
扩展。断言全部**截图/日志实证**（不采信打印）：

| # | 用例 | 断言 |
|---|---|---|
| T1 | grab→relay 链路通 | 卡片帧到达（VoicePopup 收帧日志）+ 截图 popup 位置出现 QML 卡内容 |
| T2 | 跟随精确性 | ic-sim caret 三位置序列（左上/中/右下）→ 截图三连，卡片逐次贴 caret 下方 |
| T3 | 状态覆盖 | voice 四态 + pinyin 候选各一张截图，内容与 direct 模式一致 |
| T4 | 帧节流与吞吐 | recording 动画期帧率日志（≥8fps）+ CPU 采样（sampler.py，对照 direct 档） |
| T5 | 崩溃隔离复测 | relay 模式下 kill qs → State() 存活 → 重启卡片恢复 |
| T6 | 直显回归 | QmlCardMode=direct 一轮（双卡路径不回归） |

通过标准：T1-T3 截图人工判读 + T4-T6 指标线。宿主验收沿用 0.4.x 打包流程。

## 6. 已知取舍

- grab 是 QML 场景快照：**输入焦点交互**（候选点击/hover）在 relay 模式
  下经 popup 的 pointer 路由反解坐标回传 QML（二期；原型期候选点击
  暂缺，键盘选择不受影响）。
- 帧文件中转依赖 /tmp tmpfs（容器与宿主皆成立）。
- 动画流畅度受节流率限制（10fps 起步，可调至 30fps）。
