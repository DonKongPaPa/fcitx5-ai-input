# qml-probe —— Quickshell QML Material 卡片技术底座探针（Spike）

目的：为 card-qml/（决策② DMS 风格 QML Material 卡片 → 独立 Quickshell 实例）
验证三件事：**① 传输底座**（Quickshell QML 能否收 v1 envelope，从 stdin 还是
socket）、**② layer-shell 窗口底座**（PanelWindow 锚点/margin 动态定位是否可用）、
**③ D-Bus 备用通道是否存在**。数据源用 `lab/spec/events/*.jsonl` 回放
（协议真源 `lab/spec/protocol.md`）。

结论先行：**三项全部可行，传输选 Unix socket（Quickshell.Io/Socket 客户端）**。
容器探针 6/6 断言 PASS（quickshell 0.3.2 + niri，layer surface map + 双向
envelope + margin 即时重定位全部实测通过）。

## 三问答案（宿主 /usr/lib/qt6/qml/Quickshell/ 审计）

### Q1 QML 能否读自身进程 stdin？→ 否；走 Socket

- Io 模块全类型清单见 `quickshell-io.qmltypes`（822 行，插件导出的权威注册表）：
  `DataStream` / `DataStreamParser` / `Process` / `Socket` / `SocketServer` /
  `SplitParser` / `StdioCollector` / `FileView` / `FileViewAdapter` /
  `FileViewError` / `JsonAdapter` / `JsonObject` / `IpcHandler` /
  `ProcessContext` + 透传的 `QIODevice`/`QLocalSocket`/`QProcess`。
  **没有任何类型暴露当前进程自己的 fd 0**：`Process` 的 stdout/stderr 是子进程的，
  `stdinEnabled` 只管往子进程写（quickshell-io.qmltypes:130-138）；
  `StdioCollector` 是挂在 Process 流上的收集 parser（:302-339）；
  二进制侧复核：`strings /usr/bin/qs` 只有 `StdioCollector`/`stdinEnabled` 符号。
- `FileView("/dev/stdin")` 理论上能一次性吞到 EOF，但它是整读文件语义
  （loaded/saveFailed、watchChanges），不是行流 API，驱动不了长会话协议——不采用。
- **结论：envelope 从 Unix socket 进**。Socket 客户端完整 API
  （quickshell-io.qmltypes:195-240，继承 DataStream :9-31）：
  - 属性：`connected: bool`（**目标态语义**：写 true 发起连接，异步生效，
    "will not update the property immediately"）、`path: QString`、
    继承 `parser: DataStreamParser`
  - 信号：`error(QLocalSocket::LocalSocketError)`、`connectionStateChanged`、
    `pathChanged`、继承 `readerChanged`
  - 方法：`write(data: QString)`（不自动加换行）、`flush()`
    （官方文档明说 "Remember to call flush after your last write"）
  - 配 `SplitParser`（splitMarker 默认 `"\n"`，"emitted once per delimited
    chunk"，quickshell-io.qmltypes:283-300）正好吃 v1 wire（紧凑 JSON+\n）。
- socket 路径从 addon 传给卡片：`Quickshell.env("VAR")` 可读环境变量
  （quickshell-core.qmltypes:1054-1059）。

### Q2 PanelWindow 锚点 + margin 动态定位 → 可用，margin 改动即时生效（实测）

- API（Quickshell._Window/quickshell-window.qmltypes）：`PanelWindowInterface`
  （:131-201）暴露 `anchors`（值类型 `{left,right,top,bottom:bool}`，:9-21）、
  `margins`（值类型 `{left,right,top,bottom:int}`，quickshell-core.qmltypes:612-623）、
  `exclusiveZone`/`exclusionMode`/`aboveWindows`/`focusable`，均带 notify 信号、
  map 后可写。层/键盘焦点经附加属性 `WlrLayershell.layer/namespace/keyboardFocus`
  （Wayland/_WlrLayerShell/quickshell-wayland-layershell.qmltypes:97-178，
  `WlrLayer ∈ {Background,Bottom,Top,Overlay}`）。
- **即时性为实测结论**（文档未写明）：探针在 map 后原地改 `margins.top`
  10→130，未做任何重 map 动作，窗口高度同帧级跟随（Δh=-120 = -Δtop，
  观测窗 ≤700ms，且截图确认渲染位置/尺寸已变）。layer-shell 协议下即
  margin→commit→compositor 重排。
- 陷阱：**`WlrLayershell.namespace` 在 windowConnected 后不可改**（官方文档
  "Cannot be set after windowConnected"）——卡片 namespace 要创建时定死。
- X11 回退：Quickshell.X11 有 `XPanelWindow`（quickshell-x11.qmltypes:12+），
  同为 PanelWindowInterface 子类，API 同形。

### Q3 通用 D-Bus 客户端 → 0.3.2 没有；备用路径是 Process 外调

- 全部 QML 模块里 D-Bus 相关只有：`Quickshell.DBusMenu`（tray 菜单，仅
  DBusMenuHandle/DBusMenuItem 两个类型）+ 服务级封装（Mpris/Notifications/
  SystemTray-StatusNotifier/Bluetooth 内部走 D-Bus 但不暴露通用能力）。
  没有 `Quickshell.DBus` 之类的通用 method-call/signals 客户端。
- 备用（若 addon 需要）：`Quickshell.Io/Process`（或 `Quickshell.execDetached`）
  外调 `busctl`/`gdbus`；或全部 D-Bus 交互收在 addon 的 C++ 侧，QML 只走 socket。

## 工程文件

| 文件 | 作用 |
|---|---|
| `Containerfile.qml-probe` | 派生镜像：`aiinput-niri:latest` + `quickshell`（依赖自动带 qt6-declarative/qt6-svg） |
| `run-probe.sh` | 宿主编排：构建（缺才建）→ `podman run --userns=keep-id` 挂 `/probe`（ro）、`/lab`（ro）、`/out` |
| `env/start-probe.sh` | 容器内编排：sway(headless 1920x1080) 托管嵌套 niri（复刻 `scripts/env/start-niri.sh` 模式，scale 1.0）→ feeder → qs → niri 取证 → 断言 |
| `probe-shell/shell.qml` | 最小卡片：PanelWindow（left+top+bottom 锚，namespace=aiinput-probe，WlrLayer.Top）+ Socket 客户端（SplitParser 行解析）+ 回写 select + margin 实验定时器 |
| `feeder.py` | Unix socket 服务端：按 `lab/spec/protocol.md` §2/§8 回放 jsonl（`_delay_ms` 等待、`_comment` 跳过、线上 seq 重编为全局单调——协议规定接收方不依赖 seq），并接收卡片 dir=in 回写 |
| `assert-results.py` | 断言 A1/A2（layer map：quickshell MAP_OK + `niri msg layers`）、B1/B2（envelope 逐条对拍 + dir=in 忽略）、C1（write 回程）、D1（margin 即时性 Δh=-Δtop） |

## 运行

```sh
./containers/qml-probe/run-probe.sh
# 产物默认 /tmp/aiinput-qml-probe/<ts>/（AIINPUT_QML_PROBE_OUT 可覆盖）
#   logs/{quickshell,feeder,sway}.log  niri-layers.txt  probe-screenshot.png  summary.txt
```

镜像构建（run-probe.sh 会自动做，手动等价命令）：

```sh
podman build -t localhost/aiinput-qml-probe:latest \
    -f containers/qml-probe/Containerfile.qml-probe containers/qml-probe/
```

## 探针实测记录（2026-11-01，quickshell 0.3.2 / niri 26.04 嵌套于 sway headless）

- 构建：1 次成功（≤2 次预算内）。派生层仅 `pacman -Syu quickshell`。
- 跑了 3 轮：第 1 轮 3/6（暴露 niri IPC socket 路径拼错、断言两处缺陷）；
  修正后第 2 轮 5/6（暴露 assert 脚本漏 `import json` 被 except 吞掉）；
  第 3 轮端到端 **6/6 PASS**（容器内产出 summary）。
- 最终断言（全 PASS）：
  - A1 MAP_OK layer=2(Top) width=420 height=1030 —— compositor configure 后尺寸生效；
  - A2 `niri msg layers` → Top layer: Namespace "aiinput-probe"（niri 侧独立证据）；
  - B1 feeder SENT(dir=out) 18 条 ≡ 卡片 ENV 18 条（(seq,method) 逐条对拍，
    voice-full.jsonl + pinyin-flow.jsonl 两文件，含 panel/update 候选流）；
  - B2 协议 §8：卡片把 2 条 dir=in 行判为 IGNORED；
  - C1 卡片 `Socket.write()+flush()` 回程 ready×1 + select×1 到达 feeder；
  - D1 map 后原地改 margins.top 10→130：h 1030→910（Δh=-120=-Δtop），
    未重 map；截图确认渲染形态同步变化。
- 截图（probe-screenshot.png，1920x1080）：卡片以层表面贴左缘渲染，
  CJK 文本正常，画面自带 `w=420 h=910 recv=18 send=2 last: panel/hide seq=20`。

## 已知怪癖与未验证项（如实记录）

- **嵌套 niri 逻辑输出高 = 1050 而非 1080**：外层 sway 给 niri 的窗口带
  ~30px 边框/标题。任何按输出高度硬编码的断言都会翻车，探针已改为 Δ 判据。
- niri 首次 configure 给的是未含锚点的 420x100，锚点形态随后一次 configure
  到达——判"最终 map"要等双锚尺寸（探针以 h≥500 判定）。
- niri IPC socket 文件名带 PID（`niri.wayland-N.<pid>.sock`），
  `WAYLAND_DISPLAY` 取内嵌的 `wayland-N`，`NIRI_SOCKET` 须按通配取全名。
- Socket 断线重连：error 信号（PeerClosedError/ServerNotFoundError）与重试
  逻辑实测会触发；**重连成功本身未单独验证**（feeder 关闭后无服务可连）。
- quickshell 卡片在容器内用 `QT_QUICK_BACKEND=software` 软渲染跑通；
  GL 路径未单独验证。
- stdin 结论针对 quickshell 0.3.2；未来版本若新增 stdio 源类型需复核。
- 决策④"先验证可行性，不求像素级打磨"：Material 视觉未做，探针只保底
  结构（Rectangle+Text）用于渲染证据。
