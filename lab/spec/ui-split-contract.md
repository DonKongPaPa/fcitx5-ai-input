# UI 插件化拆分契约（T1 产物）

状态：计划 v2 已批准。T5/T6 以本文为唯一事实源；接口签名以
`addon/src/hub/ui_split_iface.h` 为准（与本文冲突时以头文件为准）。

## 0. 目标与不变量

- 单体 `voiceinput.so` → 进程内双 addon：**aiinput**（引擎）/ **aiinput-ui**（UI）。
- 不变量：v1 envelope 协议不变；用户可见行为不变（语音卡定位三路径、
  rime 候选面板、探针/抢槽语义、色块回退、字体跟随、配置项全保留，
  conf/aiinput.config 仍由引擎独占读写）。
- 纪律：注释写约束不写调试叙事；程序化改文件须锚点断言 + 重读。

## 1. Addon 划分

### aiinput（引擎，T5）

- conf `Category=UI` → **`Category=Module`**（先例：
  `/usr/share/fcitx5/addon/clipboard.conf`，Module + OnDemand=False +
  Configurable=True；fcitx5 加载所有 Enabled=True 非 OnDemand 的 addon）。
- `reloadConfig/getConfig/setConfig` 是 `AddonInstance` 基类虚函数
  （/usr/include/Fcitx5/Core/fcitx/addoninstance.h:82-91），与 Category
  无关——configtool 链路无忧。基类从 `UserInterface` 改为 `AddonInstance`。
- 保留：状态机、PreInputMethod 键监听、焦点/失焦监听、ASR/refine/hub、
  TestService、字体解析后台线程、`pushUiState`、全部配置项。

### aiinput-ui（UI addon，T6）

- conf `aiinput-ui.conf.in`：`Category=UI`，`Library=aiinputui`，
  `Depends=wayland`，`Priority=Default`，`Enabled=True`，
  `Configurable=False`（其余字段照抄现 aiinput.conf.in）。
- 实现 `UserInterface` 四方法（update/available/suspend/resume）；
  update() 用原 aiinput.cpp:604-693 的 panel 翻译代码，让位判定改查
  `IAiInputEngine::voiceSessionActive()`。
- 持有：VoicePopup（三条定位路径全随之）、FlutterEngineHost、
  panelCandidates_/panelIcRef_、Flutter 资产发现（findFlutterAssets，
  aiinput.cpp:326-357）、deferredMetrics（:1005-1023）、5s 预热 timer
  （原引擎 warmupTimer_ :520-531 的职责：startFlutterEngine +
  prepare(lastFocused)，语义照抄）。
- 析构纪律照抄 aiinput.cpp:544-549：VoicePopup 故意泄漏（wayland 卸载
  后仍会 dispatch，销毁即悬垂）——注释原样搬。

## 2. 跨 addon 接口（ui_split_iface.h 已落地）

调用式：`uiAddon->call<IAiInputUi::uiShow>(ic)`。引擎取 UI addon：
`instance_->addonManager().addon("aiinput-ui", true)`，每次现取、空判
静默降级（UI addon 缺席 = 无卡片，引擎照常工作）。UI addon 取引擎：
`addon("aiinput", true)` 同法。

### 引擎 → UI（8 个）

| 方法 | 签名 | 替代的现调用点（aiinput.cpp） |
|---|---|---|
| deliverEnvelope | (string method, string argsJson) | uiBus sender 落点（:413-417 改造） |
| uiPrepare | (InputContext*) | :477 focusWatcher、（warmup 部分职责随迁） |
| uiShow | (InputContext*) | :1318/:1326 beginRecording（含 renderer 懒启 + 色块回退） |
| uiHide | () | :1556 enterIdle |
| uiSetPolicy | (string mode, string fallbackApps, bool dbusFollow) | :373-375 ctor、:747-751 reloadConfig、:768-772 setConfig |
| uiNotifyCommit | () | :1201/:1444/:1541/:1524-1528 |
| uiResolvePending | () | :1409 onAsrFinish |
| uiPrimePreedit | (InputContext*) | :1143 handleKey |

### UI → 引擎（2 个）

| 方法 | 签名 | 语义 |
|---|---|---|
| uiCommand | (string method, string argsJson) | Dart 命令回流：select（语音）/hover/ready；surface 切换重推 = uiCommand("ready","{}")（ready 分支即 pushUiState+sendFontToUi） |
| voiceSessionActive | () → bool | update() 让位判定（state_ != Idle） |

## 3. 消息路由（方向反转记录）

- **voice/*、theme**：引擎 UiBus（sender=deliverEnvelope）→ UI addon
  deliverEnvelope（guard：flutter running 才 sendMethod）→ Dart。
- **panel/***：UI addon 的 update() 本地翻译 → 本 addon 的 UiBus
  （sender=flutter sendMethod 直发）。引擎不再产生 panel/*。
- **Dart→C++ 拆分**：UI addon 收到全部 platform 消息后——
  `resize{w,h}` → 本地（popup setLogicalSize + deferredMetrics）；
  `select{"panel":true}` → 本地（panelCandidates_ + CandidateWord::select）；
  `select`[语音]/`hover`/`ready` → 引擎 uiCommand。
- 引擎 beginRecording 简化为：`uiShow(ic); pushUiState();`（envelope 在
  UI 侧 guard，renderer 未起时丢弃，色块回退在 uiShow 内部）——原
  :1321-1327 的 renderer 状态判断不再出现在引擎。

## 4. T5 文件清单（只许碰这三个）

1. `addon/src/core/aiinput.cpp`
2. `addon/src/core/aiinput.h`
3. `addon/src/aiinput.conf.in`（Category=Module）

映射表（行号为拆分前）：

| 位置 | 动作 |
|---|---|
| aiinput.h:26-27 前置声明、:92 基类、:97-105 UserInterface 四方法、:130-132 metrics 成员、:170-175 flutter 方法、:182/185-187 成员 | 删/改（基类 → AddonInstance；panelCandidates_/panelIcRef_/popup_/flutter_/deferredMetrics/metricsTimer_/pendingMW_/pendingMH_/startFlutterEngine/pushUiState 中的 popup flutter 部分清出；onFlutterMessage 改名 uiCommand 并删 resize/panel 分支；新增 ui() 访问器 + voiceSessionActive） |
| aiinput.cpp include（:2 flutter_engine.h、:4 popup_surface.h）| → 删，加 ui_split_iface.h 与 json_util.h |
| ctor :366-423 popup/flutter 全部接线 | 删；uiBus sender → deliverEnvelope（空判）|
| ctor :472-479 focusWatcher prepare | → uiPrepare |
| ctor :520-531 warmupTimer_ | 整体删（职责迁 UI addon）|
| dtor :544-549 | 空（泄漏纪律注释随迁 UI addon）|
| :326-357 findFlutterAssets、:799-816 startFlutterEngine | 删（迁 UI addon）|
| :604-709 UserInterface 四方法 | 整体删（迁 UI addon）|
| reloadConfig/setConfig 的 popup 段 | → uiSetPolicy |
| :1005-1023 deferredMetrics | 删（迁）|
| :1025-1061 onFlutterMessage | → uiCommand（只剩 select[语音]/hover/ready 分支；panel 分支删）|
| :1143 primePreedit、:1201/:1444/:1541 notifyCommit、:1409 resolvePending、:1318-1327 show、:1556 hide | → 对应 ui* 调用（空判）|
| :846-878 pushUiState、:882-1002 字体链路 | 留，不动 |

EXPORT 注册（AiInputEngine 类体内）：`FCITX_ADDON_EXPORT_FUNCTION(AiInputEngine, uiCommand)`、`FCITX_ADDON_EXPORT_FUNCTION(AiInputEngine, voiceSessionActive)`。

## 5. T6 文件清单

**新建 `addon/ui/`**：
- `ui_addon.h/.cpp`：类 `AiInputUi : public UserInterface`；构造（popup/flutter 接线照抄原 ctor :366-423 的 UI 内部部分：frame→pushFrameBGRA、pointer sink→onPointer、resize→setLogicalSize+deferredMetrics、scale handler、panel UiBus sender；popup modeSwitchHandler → 引擎 uiCommand("ready","{}")）；5s 预热 timer；UserInterface 四方法（update 翻译代码 + voiceSessionActive 让位判定）；8 个导出方法实现（deliverEnvelope/uiPrepare/uiShow/uiHide/uiSetPolicy/uiNotifyCommit/uiResolvePending/uiPrimePreedit——内部即原 popup_ 调用）；8 个 `FCITX_ADDON_EXPORT_FUNCTION(AiInputUi, ...)`；析构泄漏 popup_；`FCITX_ADDON_FACTORY(AiInputUiFactory)`。取引擎：`instance_->addonManager().addon("aiinput", true)` 空判。
- `CMakeLists.txt`：target `aiinputui`（MODULE，PREFIX ""）；源 = ui/ui_addon.cpp + ui/surfaces/popup_surface.cpp + ui/embedder/flutter_engine.cpp + ../src/hub/ui_bus.cpp + ../src/hub/json_util.cpp；协议生成块整体迁入（imv2 + foreach 五协议，原 src CMakeLists:82-121）；依赖 = Fcitx5::Core、Fcitx5ModuleWayland、Fcitx5ModuleXCB、PkgConfig xcb/xcb-shm、wayland-client、libflutter_engine.so、pthread；defines = AIINPUT_FCITX_GE_51（版本守卫同款）+ AIINPUT_VERSION_STRING；RPATH `$ORIGIN/../fcitx5-aiinput`；install = target + conf + libflutter_engine.so（原 :127-128）+ flutter assets（原 :147-158）。
- `aiinput-ui.conf.in`（见 §1）。

**迁移（git mv，保持历史）**：`addon/src/surfaces/` → `addon/ui/surfaces/`；
`addon/src/embedder/` → `addon/ui/embedder/`；`addon/src/fcitx-wayland/` →
`addon/ui/fcitx-wayland/`。

**重写 `addon/src/CMakeLists.txt`**：engine target 源 = core/aiinput.cpp +
hub/{ui_bus,stdio_backend,json_util}.cpp + asr/*.cpp；依赖 = Fcitx5::Core、
Fcitx5ModuleDBus、PkgConfig::FONTCONFIG、sherpa 两库 + RPATH、pthread；
删 = Fcitx5ModuleWayland/XCB、xcb pkg、协议生成块、flutter 块与安装、
assets 安装；保留 backends 安装与 aiinput.conf 安装（conf 内容改 Category
归 T5）。`AIINPUT_FCITX_GE_51` 两 target 都定义。

**验证性改动**：`packaging/common/stage.sh`——确认 cmake install 全量
staging 覆盖新 aiinputui.so/conf，无需改则不动；要改就在本文件内最小改。

## 6. 风险与回退

- **Module 不被启动即载**：T7 容器冒烟验证（fcitx5 -d + TestService
  State()）。回退方案：Category=UI + no-op UserInterface（update 空实现）
  压低优先级让 aiinput-ui 胜出。
- **双 .so 各持 wayland-scanner 生成码**：验证 dlopen RTLD_LOCAL 隔离；
  冲突则恢复 WL_PRIVATE 或符号前缀。
- **panel 路由**：两 UI addon（classicui + aiinput-ui）并存时 fcitx5 选
  谁由现行为决定（现状 aiinput 已胜出，同字段迁移应保持）；T8 rime 回归
  实测，必要时补 UIPriority。
- **ui_bus.cpp/json_util.cpp 编进两个 target**：各持私有副本，无跨 .so
  符号需求（两 MODULE 均默认 hidden visibility），无冲突。

## 7. T5/T6 验收（编译前自查）

- T5：`grep -n "popup_\|flutter_\|VoicePopup\|FlutterEngineHost\|popup_surface\|flutter_engine" addon/src/core/` 仅允许注释级残留=0；conf Category=Module；所有 ui 调用空判；include 清理。
- T6：`grep -rn "wayland\|xcb\|flutter" addon/src/CMakeLists.txt` 仅剩 fontconfig/sherpa 相关；ui_addon 实现四方法 + 8 EXPORT；泄漏注释在位；`git status` 显示 mv 而非 add+delete。
