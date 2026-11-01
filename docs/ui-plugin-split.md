# 将 UI 作为 Plugin 分解——可行性分析

状态：Draft（feat/ui-plugin-split 分支）
配套既定决策：① 单体 addon 库（现状 `aiinput.so`；历史包名 voiceinput 的直接后继——
包路径与配置文件迁移记录见 `aiinput.cpp:569-575`、`aiinput.cpp:711-720`）拆成
**进程内双 fcitx5 addon**（引擎 + UI）；
② DMS 风格 QML Material 卡片做成**独立 Quickshell 实例**（非 DMS 插件）；
③ 两个 UI（Flutter 卡 / QML 卡）都必须支持 rime 拼音候选面板（`panel/*` 通道）；
④ 本文先验证可行性，不求像素级打磨。

本文所有仓库引用与宿主事实均为写作时对照仓库文件与 `pacman` 实测核实（核实命令清单见 §10）。

---

## 1. 结论（TL;DR）

**可行，且仓库已为此铺好大半路。** 判断依据：

1. 协议真源 `lab/spec/protocol.md` 的星型拓扑（§1.1，`lab/spec/protocol.md:9`）早已把
   "模块拆分（core/hub/edges/surfaces/embedder）"列为 P3、"stdio/socket 传输"列为
   P6（`lab/spec/protocol.md:175-176`）——本次拆分不是推翻设计，而是**执行既有规划**。
2. `UiBus`（`addon/src/hub/ui_bus.h:18-24`）从设计起就是**传输无关**的：Sender 是注入
   的 `std::function`，注释明说"进程内为 Flutter 引擎的 platform channel，未来可换
   stdio/socket；测试可注 mock 收集"。拆分只是给 Sender 换一个注入点。
3. fcitx5 官方跨 addon 调用机制（`FCITX_ADDON_DECLARE_FUNCTION` /
   `FCITX_ADDON_EXPORT_FUNCTION`，已在
   `/usr/include/Fcitx5/Core/fcitx/addoninstance.h:172,187` 核实）且本仓已有运行先例：
   `popup_surface.h:72-74` 对 waylandim 模块的同款声明（"跨 addon 调用按名字+签名在
   运行时匹配"）。
4. `Category=Module` + `Configurable=True` 是合法组合（`/usr/share/fcitx5/addon/clipboard.conf`
   实测），引擎 addon 降为 Module 后 configtool 设置页可以保留。

主要代价与风险（详见 §6、§9）：QML 卡是独立进程，拿不到 `zwp_input_popup_surface_v2`
的合成器跟随定位（该 role 要求挂在 waylandim 的 IM 连接上，`popup_surface.h:79-86`），
只能走 layer-shell margin 重锚；X override-redirect 路径 QML 难复刻，X11 应用覆盖出现
缺口（先接受，见 §6.3）。

---

## 2. 现状：单体 addon 的五重身份

`AiInputEngine`（`addon/src/core/aiinput.h:92`）一个类同时承担五重身份：

| # | 身份 | 代码依据 |
|---|------|---------|
| 1 | **会话状态机**（Idle→Pressing→Recording→Result/Candidates） | `aiinput.h:82-91`（状态图）、`aiinput.h:139`（`enum State`）、`aiinput.cpp:1087` 起 `handleKey` |
| 2 | **ASR/refine 中枢**（引擎档切换、流式 partial、refine 子进程） | `aiinput.h:213-214`（`asr_` / `refineBackend_`）、`aiinput.h:151-153`（refine 进程外后端，P6 已落地一半） |
| 3 | **Wayland + X 定位表面**（input-popup / layer-shell / X OR 三传输） | `addon/src/surfaces/popup_surface.h:95-390`（VoicePopup：popup/layer/X11 三路，探针、policy、fractional scale、指针路由全在此） |
| 4 | **Flutter 进程内渲染**（raw embedder，软渲 → wl_shm/XShm 帧） | `aiinput.cpp:799` 起 `startFlutterEngine`、`addon/src/embedder/flutter_engine.h:40-70`、CMake 链接 `libflutter_engine.so`（`addon/src/CMakeLists.txt:42-59`） |
| 5 | **UserInterface**（给 rime/pinyin 当候选窗） | `aiinput.conf.in:3`（`Category=UI`）、`aiinput.h:97-105`（UserInterface 四方法）、`aiinput.cpp:604-693`（`update(InputPanel)` 把 IC 候选/预编辑翻译为 v1 `panel/*`） |

身份 5 的关键约束：**fcitx5 只把 InputPanel 派发给唯一活跃 UI**——
`lab/knowledge/fc-uim-single-active-dispatch.md`（uim.cpp/userinterfacemanager.cpp 5.1.21
源码核读）实测 `UserInterfaceManager::updateSingleComponent` 只调单指针 `ui_`，非全体
`uis_`；且 IC 带 ClientSideInputPanel 能力位时完全绕过 UI 插件。这就是测试环境需要
`--disable=classicui,kimpanel` 的原因。拆分后该派发约束**原样落在 UI addon 头上**：
`update(InputPanel)` 只到达当时被选中的那一个 UI，`aiinput-ui` 取代单体 addon 进入
这场竞争——但**选中者是否仍是它，取决于 fcitx5 的选择，本文不预设结论**，列为 M1
必须实测的前提（§7.3 风险 3、§9.1）。

身份 3+4+5 与身份 1+2 的耦合点（也是拆分的切割线）：

- 状态机独占表面：语音会话中 `update(InputPanel)` 直接让位（`aiinput.cpp:615-617`
  `state_ != Idle → return`）——面板与语音卡竞争同一表面。
- 表面定位逻辑依赖状态机事件：`notifyCommit`（上屏后继承跟随，`popup_surface.h:126`）、
  `primePreedit`（触发键阈值窗口内提前挂探针，`popup_surface.h:146`）、
  `resolvePendingToLayer`（录音结束仍无矩形结算 layer，`popup_surface.h:128`）。
- Flutter 消息回流状态机：`select`/`hover`/`ready` 到 `onFlutterMessage`
  （`aiinput.cpp:1025-1061`；`resize` 在 embedder 层消化，见 `aiinput.cpp:419` 注释），
  处理 `select`（语音候选提交 / panel `CandidateWord::select`）与 ready 触发的
  状态重推+字体下发（`aiinput.cpp:1056-1060`）。

---

## 3. 可复用的既有资产

- **v1 envelope 协议**（`lab/spec/protocol.md`）：三条边同封套、传输无关（§1.3）、
  版本协商 hello、无回执语义全量重推（§1.5）。`panel/*` 事件表（§4.1）与
  ui→addon 命令表（§4.2，`select`/`hover`/`navigate`/`panel/action`/`cancel`）已经
  定义了 UI 通道的双向——拆分后的 addon 间通道与未来 QML 卡通道**共用同一事件集**。
- **JSON Schema + 回放**：`lab/spec/schema/envelope.schema.json`、`events.schema.json`
  校验 envelope；`lab/spec/events/` 六个回放脚本（清单来源：`lab/spec/protocol.md:166-171`
  + 目录实测逐一比对）——`voice-full.jsonl`（语音全状态：recording 流式→candidates→
  select→idle）、`voice-result-auto.jsonl`（Result 态自动上屏倒计时路径）、
  `pinyin-flow.jsonl`（panel 逐键流+翻页+选择）、`panel-vertical.jsonl`（竖排布局）、
  `theme-change.jsonl`（字体/动画挡位热改）、`asr-refine-flow.jsonl`（三通道完整
  会话）——M1 "行为不变"的验收可直接复用。
- **行协议解析**：`addon/src/hub/proto_line.h`（扁平字段提取 + JSON 转义解码），
  已在 asr/refine stdio 后端（`backends/asr-dummy.py`、`refine-dummy.py`）跑通，
  是 stdio 传输选型的现成参照（§6.1）。
- **`UiBus` 注入式 Sender**：见 §1。引擎拆出后，"往 UI 发事件"的代码不需要改语义，
  只需要换/增 Sender。
- **知识库**：`lab/knowledge/` 沉淀的 fcitx5 API 约束（`fc-uim-single-active-dispatch`、
  `fc-input-popup-api`）、wayland 定位踩坑（`wl-input-popup-single-slot`、
  `wl-mutter-rect-storm`、`wl-rect-latency-unbounded`）、X 路径（`x-satellite-*` 系列）
  在评估 QML 路线时全部直接适用。

---

## 4. 宿主环境事实（本会话核实）

| 项 | 实测结果 | 核实方式 |
|---|---|---|
| fcitx5 | **5.1.23-1**（`fcitx5 --version` 同 5.1.23） | `pacman -Q fcitx5` |
| kimpanel | **在装**：`libkimpanel.so` + `kimpanel.conf`（`Category=UI`）内置于 fcitx5 包 | `pacman -Ql fcitx5 \| grep kimpanel` |
| quickshell | **0.3.2-1**，`/usr/bin/qs`；含 `Quickshell.Wayland._WlrLayerShell`（`WlrLayershell`：`layer/namespace/keyboardFocus/anchors/exclusiveZone/exclusionMode/margins/aboveWindows/focusable`）与 `Quickshell.Io`——`Process`（spawn 子进程、向**子进程** stdin 供数据 `stdinEnabled`）、`Socket`（客户端：`path`/`connected`/`write`/`flush`，prototype `DataStream` 带 `parser` 槽可挂 `SplitParser`）、`SocketServer`（监听 `path`，每连接实例化 `handler`）、`SplitParser`（按行拆）、`StdioCollector`（收集 `text`/`data`；**未挂接 Process 时读什么，qmltypes 无语义说明**）；`Quickshell.X11` 含 `XPanelWindow` | `pacman -Q quickshell`；qmltypes 逐类型枚举 |
| fcitx5 用户侧状态 | `~/.config/fcitx5/profile` 只含输入法组（**无 addon 启用列表**）；`~/.config/fcitx5/addon/` 目录存在且为空（无用户级 addon 描述覆盖）；配置值在 `conf/aiinput.config`（引擎写，`aiinput.cpp:592,761`） | 读本机 `~/.config/fcitx5/{profile,addon/}` |
| Material style | **内置于 qt6-declarative**：`/usr/lib/qt6/qml/QtQuick/Controls/Material/` 由 `qt6-declarative 6.12.0-3` 拥有（`pacman -Qo`）；系统**无独立 qt6-quickcontrols2 包**（Qt6 里 Controls2 属 declarative） | `pacman -Qo`；`pacman -Q \| grep quickcontrols`（仅 qt5 的） |
| qt6-declarative | 6.12.0-3 | `pacman -Q qt6-declarative` |
| 本仓已装版本 | fcitx5-ai-input 0.4.5-1 | `pacman -Q` |
| fcitx5 开发头 | `/usr/include/Fcitx5/Core/fcitx/addoninstance.h` 提供 `FCITX_ADDON_DECLARE_FUNCTION`(:172)、`FCITX_ADDON_EXPORT_FUNCTION`(:187)、`addon->call<IAddon::func>(...)`(:72) | grep 头文件 |
| `Category=Module` 先例 | `/usr/share/fcitx5/addon/clipboard.conf`：`Category=Module` 且 `Configurable=True` | 读文件 |
| 当前 Category=UI 名单 | aiinput（本仓）、classicui、kimpanel、virtualkeyboard | `grep -l "Category=UI" /usr/share/fcitx5/addon/*.conf` |

含义：QML 卡所需的一切（layer-shell 窗口、Material 控件、行协议子进程/套接字）
**宿主已齐装，零新增依赖**。

---

## 5. 路线对比

| 路线 | 说明 | 优 | 劣 | 判定 |
|---|---|---|---|---|
| **A. 进程内双 addon（选定）** | 引擎（Module）+ UI（UserInterface）两个 .so 同进程，经 addon 函数互调；Flutter 卡保持进程内嵌入 | ① 保留 input-popup 合成器跟随的全部保真（表面仍在 waylandim IM 连接上）；② 拆分以**行为零变化**为目标（M1 纯结构手术；前提是 UI 选中者不变——该前提本身列入 M1 验收，§7.3 风险 3）；③ 帧路径（BGRA→wl_shm memcpy）不变；④ 协议 v1 事件集原样作为 addon 间接口 | 仍同进程：Flutter/QML 任一崩溃拖垮 fcitx5（§6.6）；addon 间是进程内函数调用，"UI 通道"名存实不隔 | **M1 执行** |
| **B. UI 独立进程（stdio/socket）** | 卡片 UI 整体出进程（含 Flutter），addon 经 v1 envelope 行协议通信 | 崩溃隔离；符合 protocol.md P6 终态；传输可选 stdio/socket | input-popup 路径**不可达**：`zwp_input_popup_surface_v2` 必须挂 waylandim 的 IM proxy（`popup_surface.h:79-86`，一个 seat 一个 IM），外部进程拿不到 → 全部场景退 layer/X 重锚，跟随保真系统性下降；生命周期/孤儿子进程管理新增 | **作为 M2 QML 卡的形态存在**（QML 卡即 B 的 Quickshell 实例），Flutter 卡不迁 |
| **C. kimpanel（对照项）** | 复用 fcitx5 内置 kimpanel 模块（D-Bus 协议，外部面板进程渲染） | 现成、生态成熟（Plasma kimpanel widget）、D-Bus 出进程 | 数据模型是 preedit + **LookupTable 候选表**，表达不了语音卡状态（recording 流式 partial、elapsed_ms、result 倒计时、LLM 双行候选 + hover）；语音会话与拼音面板的"让位"语义无处安放；DMS 风格自绘卡片仍要自己写 | **否**，仅作"UI 出进程"的既有先例对照 |
| **D. 维持现状** | 单体 aiinput.so 不动 | 零迁移成本 | Flutter 卡与语音/候选逻辑焊死（§2 耦合点）；QML 卡无安身之处；protocol.md P3/P6 规划落空；每次 UI 实验都动引擎代码 | **否** |

选 A 的核心论据一句话：**M1 以"UI 选中者不变"为可实测、可回退的前提追求行为零
变化，拿到结构解耦；M2 的 QML 卡天然就是路线 B 的独立进程形态，两条路线不互斥，
A 是通向 B 的第一级台阶。**

---

## 6. DMS / QML 卡片专节

### 6.1 传输选型：stdin vs Unix socket

先明确两件事：**生命周期与传输是两个独立问题。** QML 卡无论选哪种传输，都由
addon spawn/kill 子进程管理生死（"独立 Quickshell 实例"指独立进程、非 DMS 插件，
不是"独立于 fcitx5 存活"）——孤儿问题由 spawn 消解，与通道选型无关。通道本身
两选一：

| | stdin/stdout（行协议直通） | Unix socket（本选型基线） |
|---|---|---|
| 协议先例 | **强**：protocol.md §2 已定义 stdio 行 wire（每行一个紧凑 envelope，`\n` 结尾），asr/refine 后端就是这套（`stdio_backend`、`proto_line.h`）；stderr 直通 fcitx5 日志（protocol.md:44） | **帧格式完全相同**（逐行 envelope，只是字节流承载换成 socket）；首条 `hello` 覆盖版本协商（protocol.md §1.4 现成） |
| 卡片侧读自身通道 | **未闭环**：已装 quickshell 0.3.2 类型清单里没有"读实例自身 stdin"的文档化类型——`Process.stdinEnabled` 是向**它 spawn 的子进程**供数据（方向相反，qmltypes 实测）；唯一候选 `StdioCollector` 在未挂接 Process 时读什么，qmltypes 未说明（§4） | **闭环**：卡作 `Socket` **客户端**——`path`+`connected`+`write`/`flush`，`parser` 槽挂 `SplitParser` 逐行收（qmltypes 全部语义实测在案）；addon 侧作 socket 服务端（C++ 监听 `$XDG_RUNTIME_DIR/fcitx5-aiinput-ui.sock`，accept 卡片连接） |
| 调试 | stderr 天然进 fcitx5 日志；行协议可直接灌 `lab/spec/events/*.jsonl` 回放 | 行协议同样可灌回放（同一解析器）；socket 流观测需 socat 中转 |
| 崩溃感知 | 子进程退出/管道 EOF | socket 断开 + 子进程退出双信号 |

**建议：M2 基线走 Unix socket（addon 为服务端、卡为 `Socket` 客户端）；stdin 降为
spike 通过后的简化选项。** 理由：socket 两端的类型与语义在安装包里全部可查证
（§4），主链路无未知依赖，本节即完整方案；stdin 的卡片侧读取是类型清单里的
**未闭环缺口**，将其定为 M2 第一项 spike（验证 `StdioCollector` 能否收实例自身
stdin）——通过则切 stdin 换取 stderr 直通日志，不通过则 socket 定案。帧格式两种
传输完全一致，切换不动事件集与解析器（`SplitParser` 对 socket 流同样适用——
`Socket` prototype `DataStream` 的 `parser` 槽即挂它的）。

### 6.2 定位保真：layer-shell margin 重锚 vs input-popup 合成器跟随

这是两条 UI 形态的**本质差异**，不是实现瑕疵：

- **Flutter 卡（M1 基线）**：popup role 由合成器按 `text_input_rectangle` 摆放
  （`popup_surface.h:79-93`）——定位权在合成器内部，逐键零延迟跟随；这是 classicui
  同款。配套的整链路技巧（探针逼矩形重报、`notifyCommit` 继承、单槽重建夺追踪，
  README「定位机制」节）都建立在这条路径上。
- **QML 卡（M2）**：独立 Quickshell 实例**拿不到 IM popup role**（§5 路线 B 同理）。
  可用的是 `WlrLayershell`（实测属性含 `anchors`/`margins`/`exclusiveZone`）：
  addon/UI 侧把光标矩形经 `panel/caret` 事件推出（protocol.md §4.1 已为此预留——
  "layer/X 路径实时重锚数据源（rectWatcher 常驻化，P4）"），QML 侧换算成
  anchors + margins 提交。代价：
  1. **一拍管道延迟**：矩形变化 → envelope → QML → `commit` 重锚，比合成器内部
     摆放多一跳；矩形延迟本身无上界（`lab/knowledge/wl-rect-latency-unbounded.md`）。
  2. **翻转/钳制自己算**：input-popup 路径合成器兜底；margin 方案下"下方放不下
     翻上方、水平钳入输出"要 QML 侧重写（参照 `popup_surface.cpp` 的
     `anchorOverlayLocked`/`x11CardPosLocked` 逻辑）。
  3. **矩形来源退化**：input-popup 的矩形来自 `text_input_rectangle` 事件；
     独立进程收不到，只能靠 fcitx5 侧 `InputContextCursorRectChanged` watcher
     （`rectWatcher_`，`popup_surface.h:335`）。mutter 同值矩形风暴必须先去重
     （~300/s，`popup_surface.h:382-384` 注释 + `lab/knowledge/wl-mutter-rect-storm.md`），
     否则风暴直接灌满通道。

**结论**：QML 卡在"合成器跟随"这一维度**结构性弱于** Flutter 卡，实测差距进对比
矩阵（§8 占位）。这是"先验证可行性"要回答的核心问题之一：差距是否可接受。

### 6.3 X override-redirect 路径：QML 难复刻（X11 应用覆盖缺口）

**场景范围先说清**：本文（及本项目全部开发/验证矩阵）只覆盖 **Wayland 会话**——
容器测试矩阵是 niri/kde/gnome 无头合成器（`make test ENV=niri`，README:176-178），
X 路径的全部已知语义围绕 **xwayland-satellite**（它把 override-redirect X 窗转成
xdg_popup 挂到聚焦 X 顶层窗、根坐标系是 satellite 屏模型，`popup_surface.h:278-285`
注释 + `lab/knowledge/x-satellite-*` 系列）。**纯 X11 会话（无 Wayland 合成器）从未
进过验证矩阵，现状单体在该场景的表现未验证、不在本文评估范围**；Quickshell 的
layer-shell 也只存在于 Wayland。下文"X11 应用"一律指 **Wayland 会话内的
XWayland 应用**。

现状 X 路径是一段高度定制的 C++：独立 xcb 连接 + `_NET_ACTIVE_WINDOW`/WM_CLASS
判定（`popup_surface.h:286-320`）、XShm 帧直贴 OR 窗、X 屏物理坐标落点计算
（`x11CardPosLocked`）、矩形物理性判别（`rectIsXPhysical`）、satellite 根坐标系模型
（上引知识库 6 篇）。

QML 卡复刻它需要：quickshell `XPanelWindow`（已装，`Quickshell.X11` 实测存在）+
把上述判定/换算全部用 QML/JS 重写 + satellite 根坐标模型重现。**M2 探针范围不做**
——X11 应用（WPS、Electron 老应用等，`GTK/QT_IM_MODULE=fcitx` 或 XWayland 无
text-input 场景）在 QML 卡下没有精确跟随路径，属**已知覆盖缺口**：

- 缓解方向（后续）：QML 卡对这些场景退 layer 底部居中兜底（现状语义里有同款
  fallback，README:169；该兜底仅在 Wayland 会话内可用——本节场景范围所限，
  纯 X11 会话不适用也不在范围内）；或 M3 之后把 X 定位服务留在 addon 侧、只把
  渲染交给 QML（混合形态）。对比矩阵留行占位（§8）。
- 与决策 ③ 的关系：`panel/*` 候选面板在 QML 卡下同样受此缺口影响——X11 应用的
  拼音候选也退兜底。Flutter 卡（M1）不受影响。

### 6.4 Material 一致性

- QML 卡：`QtQuick.Controls` 的 **Material style 内置于 qt6-declarative 6.12**
  （§4 实测，无独立包），与 DMS（DankMaterialShell，Quickshell + Material 语言）
  同一技术栈与同款视觉基线；`color`/`elevation`/动画曲线开箱即 DMS 味。
- Flutter 卡：自绘 Material（`flutter/lib/main.dart`），与 DMS 只能"形似"。
- 一致性风险：QML Material 的字体/字号跟随要走 `theme` 事件（protocol.md §4.1
  `theme{font_path,font_size,anim}` 现成）；Flutter 卡当前由 fontconfig 解析
  classicui Font（`aiinput.h:122` `resolveUiFont`）——两卡字体链路要对齐，否则
  同屏对比观感先行失分。对比矩阵留主观评分占位。

### 6.5 Flutter SDK 钉版 vs 系统 Qt：维护面差异

- Flutter 路线：`libflutter_engine.so` 必须与构建 kernel_blob 的 SDK **同 engine
  hash**（`lab/knowledge/em-engine-hash-sdk-coupling.md`），且官方工件只有 linux-x64
  **JIT** 变体（`em-jit-only.md`；`addon/src/CMakeLists.txt:42-46` 注释同）——
  每次 Flutter SDK 升级都要重取引擎、重出 kernel_blob、重验；打包要带私有
  `libflutter_engine.so`（现状装 `libdir/fcitx5-aiinput/`，`CMakeLists.txt:127-136`）。
- QML 路线：qt6-declarative/Material 是 **Arch 仓库系统包**，`pacman -Syu` 即随
  系统更新，无 vendored 二进制；代价是 Qt 大版本漂移可能动 QML 行为（6.12 → 7.x
  迁移属远期风险），维护面交给了发行版。
- 结论：QML 卡显著**降低打包与升级维护面**（不再捆绑 ~libflutter_engine.so +
  kernel_blob + icudtl.dat），这是除视觉一致性外选 QML 的第二理由。

### 6.6 崩溃隔离：进程内嵌 vs 进程外

- 现状进程内嵌：Flutter 引擎/wayland 回调任何越界 = **fcitx5 崩**。现有代码已
  处处体现这种脆弱性：addon 析构时故意泄漏 VoicePopup 防 SIGTERM SEGV
  （`aiinput.cpp:544-549`）、libxcb 漏链要上机才炸（`CMakeLists.txt:33-38` 注释）、
  wayland 事件循环与 addon 生命周期纠缠。整个 fcitx5 输入链路随卡片崩——
  语音输入出问题 = 全系统不能打字。
- QML 卡进程外：卡片崩 → addon 经 socket 断开/子进程退出感知（§6.1）→ 重启或退
  idle；fcitx5 存活。**这是独立进程最重要的工程收益。**
- M1 的双 addon 拆分**不改变** Flutter 卡的进程内属性（决策 ① 的"进程内"指 addon
  对，UI 渲染仍在 fcitx5 进程内）；崩溃隔离收益由 M2 的 QML 卡兑现。对比矩阵留
  "人为 kill 卡片 → fcitx5 存活?"一行。

---

## 7. 分离设计概要（进程内双 addon）

### 7.1 目标拓扑

```
fcitx5 进程
├── aiinput         (Category=Module, aiinput.so——沿用现名，见 §7.3 命名决策)
│     会话状态机 / 触发键 PreInputMethod watcher / focusOut
│     ASR 引擎档 + refine StdioBackend（身份 1+2）
│     配置（conf/aiinput.config）+ configtool 页 + TestService D-Bus
│     fontconfig 字体解析（resolveUiFont，aiinput.h:122）→ theme 事件
│         │  调用 UI addon（§7.2 上半）
│         ◀  uiCommand(method, args) 回流（§7.2 命令去向表）
└── aiinput-ui      (Category=UI, aiinput-ui.so——新增)
      VoicePopup 三传输表面 + Flutter embedder（身份 3+4）
      UserInterface 四方法：update(InputPanel)→panel/*（身份 5）
      UiBus（Sender=函数调用→addon 间信封直递）
      （M2）spawn/管理 quickshell 子进程 + socket 服务端（§6.1）
```

### 7.2 跨 addon 接口草案

**UI addon 导出**（`FCITX_ADDON_EXPORT_FUNCTION`，引擎侧
`FCITX_ADDON_DECLARE_FUNCTION` 声明后 `addon->call<>` 调用；方式与
`popup_surface.h:72-74` 对 waylandim 的声明同构）：

| 函数 | 对应现状 | 语义 |
|---|---|---|
| `sendEnvelope(method, argsJson)` | `uiBus_` Sender（`aiinput.cpp:413-417`） | 语音卡事件（`voice/*`、`theme`）直递 UI addon；UI 内部决定喂 Flutter 帧管线还是转发 QML 子进程 |
| `showCard(ic)` / `hideCard()` | `popup_->show(ic)` / `hide()` | 卡片显隐（含 IC 切换重建） |
| `setSessionActive(active)` | `aiinput.cpp:615-617` 的 `state_ != Idle` 判定 | 语音会话起止：UI 据此在 panel 与语音卡间让位/收回（**替代引擎直接读状态机**） |
| `setPolicy(mode, fallbackAppsCsv, dbusFollow)` | `popup_->setPositionPolicy` + `setDbusFollow`（`aiinput.cpp:747-751,768-771`） | 配置热更/保存时下发定位策略 |
| `notifyCommit(ic)` | `popup_->notifyCommit`（`popup_surface.h:126`） | 上屏后记账：chromium 矩形继承跟随 |
| `resolvePendingToLayer()` | `popup_surface.h:128` | 录音结束仍无矩形 → 结算 layer 兜底 |
| `primePreedit(ic)` | `popup_surface.h:146` | 触发键阈值窗口内提前挂预输入探针 |
| 探针三件套 `beginPreeditProbe(ic)` / `typeProbeNext(ic)` / `endPreeditProbe()` | `popup_surface.h:134-138` | 逐字组合文本逼矩形重报（引擎状态机节拍驱动） |

**引擎导出**：

| 函数 | 对应现状 | 语义 |
|---|---|---|
| `uiCommand(method, argsJson)` | `onFlutterMessage`（`aiinput.cpp:1025-1061`） | UI → 引擎命令回流，**只承载语音会话域命令**：`ready`（触发引擎重推 `pushUiState`+`theme`，对应 `aiinput.cpp:1056-1060`）、`select`（语音候选提交）、`hover`（观测钩子）、`cancel`（协议 §4.2 已定义、现状引擎尚未从 UI 收过——Esc 现走 keyWatcher，`handleKey` 内消化；接口保留） |

**v1 命令全集的去向对齐**（protocol.md §4.2 `ready`/`resize`/`select`/`hover`/
`navigate`/`panel/action`/`cancel` × 现状 `onFlutterMessage` 只处理
`select`/`hover`/`ready`）：

| 命令 | 拆分后执行者 | 说明 |
|---|---|---|
| `ready` | 引擎（经 `uiCommand`） | 状态重推 + 字体下发（`aiinput.cpp:1056-1060` 语义迁回引擎） |
| `resize` | UI addon 本地 | embedder 尺寸，UI 侧直消化（现状由 embedder 层处理，`aiinput.cpp:419` 注释） |
| `select`（语音态） | 引擎（经 `uiCommand`） | `commitCandidate`，状态机域 |
| `select`（panel 态，`panel:true`） | **UI addon 本地** | `CandidateWord::select(ic)`——`panelCandidates_` 随 `update()` 迁入 UI addon（§7.5），引擎已退出 panel 路径，**引擎无处执行**，故不走 uiCommand（现状逻辑 `aiinput.cpp:1040-1046` 原样随迁） |
| `hover` | 引擎（经 `uiCommand`） | 测试观测钩子（`aiinput.cpp:1052-1055`） |
| `cancel` | 引擎（经 `uiCommand`） | 协议已定义、现状未实现；预留给 UI 侧 Esc/取消转发 |
| `navigate` / `panel/action` | **UI addon 本地** | 均操作 `CandidateList`（Pageable/CursorMovable/Actionable，protocol.md §4.2）；P4 未实现，协议占位——实现时归持有列表的 UI addon |

约定：两边**互不写 Depends**（循环依赖），运行时懒解析——参照 `ensureTestService`
对 dbus 模块的取法（`aiinput.cpp:776-793`，取不到重试）；首次调用即缓存
`AddonInstance*`。事件语义沿用 v1：无回执、全量重推（protocol.md §1.5），M1 的
`pushUiState`（`aiinput.h:172`）就是现成的全量重推入口。

### 7.3 conf 变更：引擎 `Category=Module` 及其加载语义、风险与回退

**变更**：
- 引擎：沿用现名与现文件——`addon/src/aiinput.conf.in:3` `Category=UI` →
  `Category=Module`，库名 `aiinput.so`、描述文件 `aiinput.conf`、配置文件
  `conf/aiinput.config` 全部**不变**。
- UI：新增 `aiinput-ui.conf.in`（`Category=UI`，`Library=aiinput-ui`；`Depends=`
  不含 engine，见 §7.2 懒解析约定）。包安装两份 conf（`CMakeLists.txt:143-145`
  同款流程复制）。
- **命名决策**：引擎保持 addon 名 `aiinput` 不改名（`aiinput-engine` 之类新名否决）。
  依据：① 配置文件路径由引擎代码写死（`safeSaveAsIni(config_, "conf/aiinput.config")`，
  `aiinput.cpp:592,761`）且历史迁移链（voiceinput→aiinput，`aiinput.cpp:711-720`）
  已有一次，再改名要第三套迁移逻辑；② 本机实测 `~/.config/fcitx5/profile` 只含
  输入法组、无 addon 级启用列表，`~/.config/fcitx5/addon/` 目录存在且为空（§4）——
  addon 名是任何用户侧状态/描述覆盖的键，引擎同名即零迁移；③ TestService D-Bus
  路径、configtool 页归属引擎，全部不动。唯一新键 `aiinput-ui` 无历史包袱。

**加载语义**（对照 §4 实测与知识库）：
- Module 类 addon 与 UI 类 addon 都在启用时实例化、都能 watchEvent/注册 D-Bus
  （clipboard 先例）；差别只在 UserInterfaceManager 的派发：**只有唯一活跃 UI 收
  `update(InputPanel)`**（`lab/knowledge/fc-uim-single-active-dispatch.md`）。
- 拆分后 `aiinput-ui` 取代单体 addon 参与 UI 竞争（对手仍是 classicui/kimpanel/
  virtualkeyboard，§4 名单），派发规则与现状一致；引擎侧不再实现 UserInterface
  四方法。
- `Configurable=True` 可保留在引擎（clipboard 同款，§4），configtool 设置页不丢。

**风险**：
1. **加载顺序**：引擎构造期即要调 UI addon（`primePreedit` 等是事件驱动，风险低；
   但 warmup 定时器里若直接碰 UI 要懒解析兜底）。全事件驱动 + 懒 `addon()` 调用
   天然规避，M1 验收时以 journal 确认无"addon not found"。
2. **迁移面**：引擎同名同配置路径，配置值、configtool 页、TestService 路径无感；
   包升级换 conf 只动 `Category` 一行。边界情形：若某用户曾显式禁用过旧单体，
   该禁用状态作用于同名引擎——升级后引擎被禁而新 UI addon 默认启用，出现"UI
   在、引擎不在"的空转（无状态机，UI 不显卡片，panel 仍由 classicui 竞争）。
   处置：`aiinput-ui` 发布时默认 `Enabled=True` 的前提是引擎默认启用（现包即
   `Enabled=True`，`aiinput.conf.in:9`），升级说明注明该组合；不再另做迁移代码。
   **包升级瞬间**旧 conf 被换新——升级/回滚事务中 fcitx5 若热重载需重启
   （fc-addon-reload 知识条目：远程 `-R` 才可靠），发布说明写明"升级后重启 fcitx5"。
3. **UI 竞争变化**：理论上多了一个 Category=UI 候选不影响唯一活跃选择，但
   classicui 的 `available()` 恒真与我们的 `available()` 恒真（`aiinput.cpp:695-700`）
   并存时实际选中者由 fcitx5 内部策略定——这是 M1"行为零变化"目标的**唯一行为
   前提**，用 `--disable=classicui,kimpanel` 测试矩阵 + 真机 configtool 里手动
   切换各验一遍；不满足则按 §9.1 收敛。

**回退（重做后的可执行版）**：
- **主回退 = 包级回退**：`pacman -U fcitx5-ai-input-<旧版>-*.pkg.tar.zst` 装回旧
  单体包（Releases 保留全部历史版本），或 git revert 分支后重打包；重启 fcitx5
  即回现状。配置 `conf/aiinput.config` 引擎同名共用，回退无损。
- **不提供"同包新旧双装运行期切换"**（替代原方案的"双 conf 并存 +
  `Enabled=False` 关新 UI"）：新旧引擎是同一身份的两份实现——状态机、触发键
  PreInputMethod watcher、TestService D-Bus 路径完全相同，同进程并存 = 双状态机
  双拦截 + D-Bus 注册冲突；只关 `aiinput-ui` 挡不住新引擎实例化。此路不通，
  废弃。
- M1 的过程保险改为**流程性**：拆分以一系列可构建提交推进，容器套件逐提交全绿
  后才合并；回归即 revert 对应提交。过渡期如需临时停用拆分产物：configtool 禁用
  两 addon（或临时移走两份 conf）后装回旧包——与包级回退是同一动作。

### 7.4 CMake 双 target 划分

```
aiinput（引擎）:  core/aiinput.cpp  hub/stdio_backend.cpp  hub/ui_bus.cpp(引擎侧发射语义)
                 asr/*(4 引擎)     aiinput.conf.in（Category=Module，§7.3）
aiinput-ui:      surfaces/popup_surface.cpp  embedder/flutter_engine.cpp
                 hub/ui_bus.cpp(UI 侧/共享头)  aiinput-ui.conf.in
共享:            hub/proto_line.h 等纯头 + 版本宏（-DAIINPUT_VERSION_STRING）
链接归属:        引擎=fontconfig（resolveUiFont 产出 theme，aiinput.h:122——配置
                   归引擎，故链接随引擎；现状 CMakeLists:76-77 的 FONTCONFIG 块
                   迁入此 target）+ sherpa-onnx + pthread + Fcitx5::Module::DBus
                 UI=libflutter_engine + Fcitx5::Module::Wayland/XCB + xcb
                   （xcb-shm，X 路径；CMakeLists:79-80 的 XCB 块留此）
                   + wayland-scanner 生成件(imv2/layer/fract…, CMakeLists:82-119)
rpath/install:   libflutter_engine.so/libsherpa-onnx 继续装 libdir/fcitx5-aiinput/
                 （$ORIGIN 相对，两 target 同引）
```

划分原则：**移动不改写**——M1 只搬文件/改 target，不动函数体（除 §7.2 接口注入
点）；`ui_bus.cpp` 两个 target 各编一份（纯无状态组包）避免引静态库的可见性问题。

### 7.5 `panel/*` 方向反转说明

- **现状**：引擎是 UserInterface——fcitx5 → 引擎 `update(InputPanel)`
  （`aiinput.cpp:604-693`）→ 引擎组包 `panel/update` → UiBus → Flutter。
  翻译权、`panelCandidates_` 持有（`aiinput.cpp:626`）、`select` 回流都在引擎。
- **拆分后**：`update(InputPanel)` 由 **UI addon** 直接收（它才是活跃 UI）。
  数据流变为：fcitx5 → **UI addon**（翻译 InputPanel → `panel/*`，持有
  CandidateList）→ Flutter（M1）或 → QML 卡（M2）。引擎**完全退出 panel 路径**。
- "反转"的实质：**panel 的生产者与消费者换位**——旧链路"引擎组包推给 UI"变成
  "UI 自产自销"；panel 候选的 `select`（含 `navigate`/`panel/action` 的未来实现）
  随 `panelCandidates_` 一并落到 UI addon 本地执行（§7.2 命令去向表），引擎与
  panel 的唯一残余联系是会话让位信号（`setSessionActive`，§7.2）。
- 风险：UI addon 接手 `update()` 后要复刻引擎里的守门语义——空 panel →
  `panelHide` + 状态清理（`aiinput.cpp:619-624`）、语音会话让位（改由
  `setSessionActive` 驱动）、5.0/5.1 comment() 版本分支（`aiinput.cpp:655-661`）。
  逐条对照验收，防"面板首字符丢失"类回归。

---

## 8. 里程碑与对比矩阵

### M1：拆分（行为不变）

范围：§7 全部；不新增任何功能。
验收：容器 34 例套件（`make test ENV=niri`，README:176-178）全绿；
`lab/spec/events/*.jsonl` 回放结果与拆分前逐字节一致；`--disable=classicui,kimpanel`
下 rime 拼音候选面板路径回归通过；journal 无 addon 加载/顺序告警。
回退：见 §7.3。

### M2：QML 卡片 + 对比

范围：`Quickshell` 子进程卡片（DMS 风格 Material QML，addon spawn 管生命周期）接
v1 ui 通道——**基线 Unix socket（addon 服务端 + 卡 `Socket` 客户端，§6.1）**；
首项 spike 为 stdin 可行性（`StdioCollector` 自身 stdin 语义验证，通过则切 stdin）；
语音卡 + `panel/*` 候选面板双支持（决策 ③）；与 M1 Flutter 卡同条件实测。
验收口径：protocol.md schema 全过；对比矩阵填数。

### 对比矩阵

**内存/CPU 已实测**（2026-11-01，容器 headless niri 1080p scale1.0；A/B 轮
workload=smoke s1-s5 真实录音会话、C 轮=voice-full+pinyin-flow 回放 20 条；
200ms 采样 /proc VmRSS。A=全栈 fcitx5（内嵌 Flutter kSoftware JIT）、
B=引擎-only（AIINPUT_DIST 屏蔽 aiinputui）、C=card-qml 独立 quickshell
（QT_QUICK_BACKEND=software）。容器数字，宿主会话只高不低）：

| 维度 | Flutter 卡（M1 基线） | QML 卡（M2） |
|---|---|---|
| 首帧延迟（触发→卡片可见） | （待实测） | （待实测） |
| 跟随延迟（rect 变化→重锚落屏） | （待实测） | （待实测） |
| input-popup 场景跟随保真（逐键） | （待实测） | （结构性弱，§6.2） |
| **常驻内存（idle 稳态）** | **fcitx5 100MB**（引擎-only 87MB → UI addon +13MB） | **fcitx5 87MB + quickshell 97~122MB ≈ 184~209MB**（独立进程） |
| **会话期内存（语音卡渲染中）** | **fcitx5 253~263MB**（UI 增量 +165~175MB） | **合计 ≈209MB**（87 + 122） |
| **全局峰值（含 sherpa deep 试加载叠加）** | **fcitx5 663MB** | **合计 ≈340MB**（fcitx5 216 + quickshell 124） |
| **会话期 CPU 均值** | **fcitx5 52.8%**（同条件引擎-only 4.8%） | **quickshell 1.3%**（峰值 19.9%，渲染瞬间） |
| kill 卡片 → fcitx5 存活 | （进程内，否） | （进程外，应存活——待实测） |
| X11 应用覆盖（WPS/Electron） | （现有 X OR 路径） | （缺口，§6.3，待实测兜底表现） |
| 混缩放多屏 fractional | （已验证） | （待实测） |
| Material 一致性（主观） | （基线） | （待实测） |
| 打包体积/维护面 | （含 flutter 引擎私有库） | （零新增依赖） |

内存结论（M2 前瞻）：Flutter UI 的真实代价被拆分显性化——idle +13MB、
会话渲染 +165~175MB、峰值 +447MB（JIT 引擎工作集 + 软渲帧缓冲；raw
embedder 官方工件只有 JIT 变体，CMakeLists 注释在案）。QML 卡单进程
122MB 但**不进 fcitx5**：会话期总占用低 40~50MB、峰值近乎砍半，且崩溃
隔离是结构性收益。idle 期 QML 方案多一个完整 Qt 进程（~110MB），若最终
采纳需做 idle unmap + 常驻取舍评估。基准复跑入口：
`containers/qml-probe/run-card-bench.sh`（C）、`AIINPUT_DIST=…/dist-engineui-off
SUITE=smoke ./scripts/run-test.sh niri`（B）。

---

## 9. 风险与开放问题

1. **UI 选中规则**：M1 后向 fcitx5 注册 UserInterface 的仍是四个——`aiinput-ui`、
   classicui、kimpanel、virtualkeyboard（§4 名单）。QML 卡是 `aiinput-ui` spawn 的
   独立渲染进程，**不注册 UserInterface、不参与竞争**（§7.1 拓扑），不进本条。
   待实测的是 `aiinput-ui` 与 classicui/kimpanel 的唯一活跃选择规则及用户手动
   切换行为（§7.3 风险 3）——它是"行为零变化"目标的唯一前提。
2. **QML 卡的键盘导航**：`panel/*` 的 `navigate`（protocol.md §4.2）在 Quickshell
   卡里靠 `keyboardFocus`（WlrLayershell 实测属性）抓键盘——layer 表面抢焦点对
   正在打字的应用是否有干扰，M2 探针项（次于 §6.1 的 stdin spike）。
3. **X11 缺口的兜底质量**：产品范围收敛为 Wayland 会话（§6.3 场景声明）后，本条
   只剩一个开放点：XWayland 应用下 QML 卡退 layer 底部居中兜底的实际观感与
   可用性（M2 实测）。纯 X11 会话不在范围——若未来要支持需另立议题，现状
   Flutter 卡同样未验证过该场景。
4. `libflutter_engine.so` 长期钉版成本持续存在（§6.5）——若 M2 对比证明 QML 卡
   全面可接受，Flutter 卡可降级为兼容保留。

---

## 10. 核实记录（本会话执行）

事实点 → 来源（命令或文件）：

- `pacman -Q fcitx5 fcitx5-qt fcitx5-configtool` → `fcitx5 5.1.23-1`；
  `fcitx5 --version` → `5.1.23`。
- `pacman -Q quickshell` → `quickshell 0.3.2-1`；qmltypes 逐类型枚举：
  `_WlrLayerShell`（WlrLayershell 属性清单）、`Io`——`Process`（属性
  `command/workingDirectory/environment/clearEnvironment/stdout/stderr/stdinEnabled`，
  其中 `stdinEnabled` 面向其 spawn 的子进程）、`Socket`（prototype `DataStream`，
  属性 `path/connected`、方法 `write/flush`、`parser` 槽）、`SocketServer`
  （`path/active/handler`）、`SplitParser`、`DataStream`（`parser` 属性）、
  `StdioCollector`（`text/data/waitForEnd`，未挂接 Process 时的数据源 qmltypes
  无说明）、`X11`（XPanelWindow）。
- `cat ~/.config/fcitx5/profile` → 仅 `[Groups/0]` 输入法组，无 addon 启用列表；
  `ls ~/.config/fcitx5/addon/` → 空目录；`ls ~/.config/fcitx5/conf/` →
  `aiinput.config`、`voiceinput.config`、`classicui.conf` 等（addon 配置值域）。
- `pacman -Qo /usr/lib/qt6/qml/QtQuick/Controls/Material/` →
  `由 qt6-declarative 6.12.0-3 所拥有`；`pacman -Q | grep quickcontrols` → 仅 qt5
  存在，qt6 无独立包。
- `pacman -Ql fcitx5 | grep kimpanel` → `libkimpanel.so` + `kimpanel.conf`；
  `grep Category= /usr/share/fcitx5/addon/{clipboard,classicui,kimpanel,waylandim}.conf`
  → Module/Frontend/UI/UI；`grep -l "Category=UI" /usr/share/fcitx5/addon/*.conf`
  → 含 aiinput、classicui、kimpanel、virtualkeyboard。
- `cat /usr/share/fcitx5/addon/clipboard.conf` → `Category=Module` +
  `Configurable=True` + `OptionalDependencies` 先例。
- `grep FCITX_ADDON_* /usr/include/Fcitx5/Core/fcitx/addoninstance.h` →
  DECLARE(:172)/EXPORT(:187)/call(:72)。
- 仓库文件核读：`addon/src/core/aiinput.{h,cpp}`（五重身份、handleKey、
  update/UserInterface、onFlutterMessage、ensureTestService、析构泄漏注释）、
  `addon/src/hub/ui_bus.{h,cpp}`、`addon/src/hub/proto_line.h`、
  `addon/src/surfaces/popup_surface.h`、`addon/src/embedder/flutter_engine.h`、
  `addon/src/aiinput.conf.in`、`addon/src/CMakeLists.txt`、`lab/spec/protocol.md`、
  `lab/spec/schema/`、`lab/spec/events/`（`ls` 实测六脚本：`voice-full.jsonl`、
  `voice-result-auto.jsonl`、`pinyin-flow.jsonl`、`panel-vertical.jsonl`、
  `theme-change.jsonl`、`asr-refine-flow.jsonl`——与 protocol.md §8 清单一一对应）、
  `README.md`、
  `flutter/lib/main.dart`（`_onTransportMessage`，:226）、
  `lab/knowledge/{fc-uim-single-active-dispatch,fc-input-popup-api,
  em-engine-hash-sdk-coupling,em-jit-only}.md`。
- 修订轮补查（针对审读意见）：`sed -n '100,175p'` / `sed -n '190,310p'` /
  `sed -n '1,40p'` `/usr/lib/qt6/qml/Quickshell/Io/quickshell-io.qmltypes` →
  `Process.stdinEnabled` 为向子进程供 stdin、`Socket`（`path/connected/write/
  flush` + `parser` 槽）、`SocketServer`（`path/active/handler`）、`StdioCollector`
  语义无说明、`DataStream.parser` 存在——§6.1 socket 基线结论据此；
  `cat ~/.config/fcitx5/profile`（addon 启用列表不在 profile）——§7.3 命名决策据此。
- 未执行/未验证：容器测试套件、quickshell 运行时行为（未启动任何图形程序，
  遵守本次纪律）——相关结论均标注为"实测/待实测"。
